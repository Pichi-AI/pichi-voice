#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-onboarding-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
run_case() {
    task_case_name="$1"
    shift
    xcrun swiftc -O -parse-as-library "$@" "Tests/$task_case_name.swift" -o "$task_test_dir/$task_case_name"
    "$task_test_dir/$task_case_name"
}
run_case OnboardingAISetupControllerTests Sources/Fluid/Services/OnboardingAISetupController.swift
run_case OnboardingPolishPracticeTests Sources/Fluid/Services/OnboardingPolishPractice.swift
run_case OnboardingDictationOutputPolicyTests Sources/Fluid/Services/OnboardingDictationOutputPolicy.swift
run_case PrivateAIHardwareRecommendationTests Sources/Fluid/Services/PrivateAIHardwareRecommendation.swift
run_case DesktopOnboardingNavigationTests Sources/Fluid/UI/DesktopOnboardingNavigation.swift
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/AccountModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Persistence/ProtectedDataAccessError.swift Sources/Fluid/Account/Account*.swift Sources/Fluid/UI/DesktopAccountGuestContinuation.swift \
    Sources/Fluid/UI/DesktopAccountProjection.swift \
    Tests/DesktopAccountGuestContinuationTests.swift -o "$task_test_dir/DesktopAccountGuestContinuationTests"
"$task_test_dir/DesktopAccountGuestContinuationTests"
python3 -S - "$task_test_dir/CloudContractValues.swift" <<'PY'
from pathlib import Path
import sys
def declaration(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
files = {
    'Sources/Fluid/Services/CloudPublication/PichiCloudPublicationService.swift': [
        'nonisolated enum PichiCloudPublicationAvailability:', 'nonisolated enum PichiCloudPublicationStatus:',
        'nonisolated struct PichiCloudPublicationSnapshot:'],
    'Sources/Fluid/Services/CloudPublication/PichiPublicationOutboxStore.swift': [
        'nonisolated enum PichiPublicationPauseReason:'],
    'Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationSource.swift': [
        'nonisolated enum PichiPublicationWithholdingReason:'],
    'Sources/Fluid/Services/CloudPublication/PichiPublicationWire.swift': [
        'nonisolated enum PichiPublicationAnalysisState:', 'nonisolated struct PichiPublicationReceipt:',
        'nonisolated struct PichiPublicationAssessment:', 'nonisolated struct PichiPublicationAssessmentOptions:'],
    'Sources/Fluid/Account/AccountDomain.swift': [
        'nonisolated enum AccountSessionState:', 'nonisolated struct AccountIdentity:',
        'nonisolated struct AccountContext:', 'nonisolated struct AccountSnapshot:',
        'nonisolated enum AccountError:'],
    'Sources/Fluid/Account/PrivateProfileService.swift': [
        '@MainActor protocol PrivateProfileTransitionParticipant:'],
}
values = 'import Foundation\n'
models = Path('Sources/Fluid/Services/Meeting/MeetingModels.swift').read_text()
values += next(line for line in models.splitlines() if line.startswith('typealias MeetingSessionID =')) + '\n'
for path, markers in files.items():
    source = Path(path).read_text()
    values += '\n'.join(declaration(source, marker) for marker in markers) + '\n'
# Receipt validation belongs to the wire probe. Keep its actual value contract
# while omitting only the private validator's unrelated request/crypto dependency.
wire = Path('Sources/Fluid/Services/CloudPublication/PichiPublicationWire.swift').read_text()
values = values.replace(declaration(wire, '    fileprivate func validate() throws'), '')
values = values.replace(declaration(wire, '    fileprivate func encoded(representedParticipants:'), '')
Path(sys.argv[1]).write_text(values)
PY
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/CloudModuleCache" \
    "$task_test_dir/CloudContractValues.swift" Tests/Support/StandaloneCloudPublicationUI.swift \
    Sources/Fluid/Account/PrivateProfileOperationOwner.swift Sources/Fluid/UI/DesktopAccountProjection.swift \
    Sources/Fluid/UI/DesktopCloudPublicationPresentation.swift Sources/Fluid/UI/DesktopCloudPublicationCopy.swift \
    Sources/Fluid/UI/DesktopCloudPublicationView.swift Tests/DesktopCloudPublicationUITests.swift \
    -o "$task_test_dir/DesktopCloudPublicationUITests"
"$task_test_dir/DesktopCloudPublicationUITests"
python3 -S - "$task_test_dir/CloudCopy.bundle" <<'PY'
from pathlib import Path
import json, plistlib, sys
bundle = Path(sys.argv[1])
bundle.mkdir()
fixture = json.loads(Path('Tests/Fixtures/N3CloudCopyContract.json').read_text())
for language in ('en', 'ru'):
    resource = bundle / (language + '.lproj')
    resource.mkdir()
    (resource / 'Localizable.strings').write_text('\n'.join(
        json.dumps(key, ensure_ascii=False) + ' = ' +
        json.dumps(value[language], ensure_ascii=False) + ';' for key, value in fixture['strings'].items()) + '\n')
(bundle / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'synthetic.cloud-copy-contract', 'CFBundleDevelopmentRegion': 'en',
    'CFBundleLocalizations': ['en', 'ru'],
}))
PY
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -D PICHI_REAL_LOCALIZATION \
    -module-cache-path "$task_test_dir/CloudModuleCache" \
    "$task_test_dir/CloudContractValues.swift" Tests/Support/StandaloneCloudPublicationUI.swift \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Account/PrivateProfileOperationOwner.swift \
    Sources/Fluid/UI/DesktopCloudPublicationPresentation.swift Sources/Fluid/UI/DesktopCloudPublicationCopy.swift \
    Tests/DesktopCloudPublicationFormatTests.swift -o "$task_test_dir/DesktopCloudPublicationFormatTests"
"$task_test_dir/DesktopCloudPublicationFormatTests" "$task_test_dir/CloudCopy.bundle"
