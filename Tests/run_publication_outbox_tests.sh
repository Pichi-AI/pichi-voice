#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/publication-outbox-tests"
mkdir -p "$task_test_dir"
# The raw executable has no app catalog. Keep title presentation resources explicit
# and isolated so the deletion guard exercises two genuinely different languages.
task_title_catalog="$task_test_dir/PublicationTitleCatalog.bundle"
mkdir -p "$task_title_catalog"
python3 -S - "$task_title_catalog/Info.plist" <<'PY_TITLE_CATALOG'
from pathlib import Path
import plistlib
import sys
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.voice.publication-title-catalog.fixture',
    'CFBundleDevelopmentRegion': 'en',
}))
PY_TITLE_CATALOG
xcrun xcstringstool compile Sources/Fluid/Localization/Localizable.xcstrings \
    --output-directory "$task_title_catalog" --language en --language ru
# Real N1/N2/domain/exporter/wire code; only unrelated inference/sidecar app support
# follows the existing checkpoint runner's generated standalone support convention.
cat > "$task_test_dir/ApplicationSupport.swift" <<'SWIFT'
import Foundation
nonisolated final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
    func warning(_ message: String, source: String) {}
    func error(_ message: String, source: String) {}
}
nonisolated struct MeetingBackendID: Codable, Equatable, Sendable { let rawValue: String }
nonisolated enum MeetingAnalysisManifestSchema { static let mappingToleranceSeconds = 0.000_001 }
nonisolated struct MeetingResultSidecarStore {
    let sessionDirectory: URL
    struct Sidecar { struct Manifest { let presentationOriginSeconds: TimeInterval }; let analysisManifest: Manifest }
    static func fileName(for id: UUID) -> String { preconditionFailure("Unexpected canonical-sidecar migration") }
    func read(expectedAttemptID: UUID, expectedBackendID: MeetingBackendID,
              reference: MeetingResultSidecarReference) throws -> Sidecar {
        preconditionFailure("Unexpected canonical-sidecar migration")
    }
}
SWIFT
python3 - "$task_test_dir/ApplicationSupport.swift" <<'PY_SUPPORT'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift').read_text()
versions = [line.strip() for line in source.splitlines() if line.strip().startswith('nonisolated static let pipelineVersion =')]
if len(versions) != 1:
    raise SystemExit('Expected one production pipeline version declaration')
with Path(sys.argv[1]).open('a') as target:
    target.write('\nnonisolated enum MeetingProcessingPipeline { ' + versions[0] + ' }\n')
PY_SUPPORT
python3 Tests/Support/write_attribution_standalone_types.py "$task_test_dir/AttributionTypes.swift"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Persistence/ProtectedDataAccessError.swift \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/AccountDomain.swift Sources/Fluid/Account/AccountPKCE.swift \
    Sources/Fluid/Account/AccountPublicationConfiguration.swift Sources/Fluid/Account/AccountLegacyTransport.swift  Sources/Fluid/Account/AccountLegacySessionStore.swift Sources/Fluid/Account/AccountSessionService.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileService.swift Sources/Fluid/Account/PrivateProfileMeetingStore.swift \
    Sources/Fluid/Services/Meeting/MeetingRecordingCipher.swift \
    Sources/Fluid/Services/Meeting/MeetingRecordingKeychainStore.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    Sources/Fluid/Services/Meeting/MeetingAutomaticNaming.swift \
    Sources/Fluid/Services/Meeting/MeetingTitleLanguage.swift \
    Sources/Fluid/Services/Meeting/MeetingUniversalTitleEngine.swift \
    Sources/Fluid/Services/Meeting/MeetingSummaryInput.swift \
    Sources/Fluid/Services/Meeting/MeetingSavedSummary.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistenceValidation.swift Sources/Fluid/Services/Meeting/MeetingSessionStore.swift \
    Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift Sources/Fluid/Services/Meeting/MeetingRetainedProcessingCheckpoint.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift \
    "$task_test_dir/AttributionTypes.swift" "$task_test_dir/ApplicationSupport.swift" \
    Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationSource.swift \
    Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationPayload.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationWire.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationRetryPolicy.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationOutboxStore.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationConsentStore.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationHTTPClient.swift \
    Sources/Fluid/Services/CloudPublication/PichiCloudPublicationService.swift \
    Sources/Fluid/Services/CloudPublication/PichiCloudPublicationActivation.swift \
    Tests/PichiPublicationOutboxTests.swift Tests/PichiCloudPublicationServiceTests.swift Tests/PichiLegacyCloudPublicationServiceTests.swift Tests/PichiAutomaticCloudPublicationTests.swift -o "$task_test_dir/tests"
PICHI_PUBLICATION_TEST_CATALOG_BUNDLE="$task_title_catalog" \
    "$task_test_dir/tests" "$task_test_dir/fixtures-$(uuidgen)" "$@"
