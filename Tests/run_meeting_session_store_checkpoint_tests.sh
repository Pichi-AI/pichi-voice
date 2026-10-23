#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/meeting-session-store-tests"
mkdir -p "$task_test_dir"
# The complete store and production persisted codecs compile unchanged. This bounded test
# never supplies a canonical sidecar, so make accidental migration reads fail loudly instead
# of linking inference/runtime orchestration or launching the application.
cat > "$task_test_dir/ApplicationSupport.swift" <<'SWIFT'
import Foundation
nonisolated enum AppBrand { static let storageNamespace = "unused-standalone-test-namespace" }
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
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -O \
    -module-cache-path "$task_test_dir/module-cache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationSource.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift \
    "$task_test_dir/AttributionTypes.swift" \
    Sources/Fluid/Services/Meeting/MeetingPersistenceValidation.swift \
    Sources/Fluid/Services/Meeting/MeetingSessionStore.swift \
    Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift \
    Sources/Fluid/Services/Meeting/MeetingRetainedProcessingCheckpoint.swift \
    "$task_test_dir/ApplicationSupport.swift" Tests/MeetingSessionStoreCheckpointTests.swift \
    Tests/MeetingTranscriptReadingContractTests.swift \
    Tests/MeetingProtectedTranscriptExportTests.swift \
    Tests/PichiProtectedPublicationSourceTests.swift \
    -o "$task_test_dir/checkpoint-tests"
"$task_test_dir/checkpoint-tests" "$task_test_dir/fixtures-$(uuidgen)" "$@"
