#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/publication-outbox-tests"
mkdir -p "$task_test_dir"
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
python3 Tests/Support/write_attribution_standalone_types.py "$task_test_dir/AttributionTypes.swift"
task_payload_source=()
if [ -f Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationPayload.swift ]; then
    task_payload_source+=(Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationPayload.swift)
fi
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/AccountDomain.swift Sources/Fluid/Account/AccountPKCE.swift \
    Sources/Fluid/Account/AccountSessionService.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift \
    "$task_test_dir/AttributionTypes.swift" "$task_test_dir/ApplicationSupport.swift" \
    Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationSource.swift \
    ${task_payload_source[@]+"${task_payload_source[@]}"} \
    Sources/Fluid/Services/CloudPublication/PichiPublicationWire.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationRetryPolicy.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationOutboxStore.swift \
    Tests/PichiPublicationOutboxTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir/fixtures-$(uuidgen)"
