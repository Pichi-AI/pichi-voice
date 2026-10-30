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
nonisolated enum AppBrand {
    static let storageNamespace = "unused-standalone-test-namespace"
    static let keychainService = "unused-standalone-test-credentials"
    static let applicationSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("unused-profile-" + UUID().uuidString)
}
nonisolated enum BrandDistribution { struct AccountConfiguration: Sendable {} }
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
# Project the authoritative shared version, without linking capture/model orchestration.
python3 -S - "$task_test_dir/PipelineVersion.swift" <<'PYCODE'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift').read_text()
versions = [line.strip() for line in source.splitlines() if line.strip().startswith('nonisolated static let pipelineVersion =')]
assert len(versions) == 1, 'The pipeline owns one authoritative version'
Path(sys.argv[1]).write_text('nonisolated enum MeetingProcessingPipeline {\n    ' + versions[0] + '\n}\n')
PYCODE
python3 Tests/Support/write_attribution_standalone_types.py "$task_test_dir/AttributionTypes.swift"
python3 - "$task_test_dir/ContentCaptureCaller.swift" <<'PY_CALLER'
from pathlib import Path
import sys
source = Path("Sources/Fluid/ContentView.swift").read_text()
stop_start = source.index("    private func stopAndProcessTranscription(")
stop_end = source.index("    // Keep the ordered dictation delivery path", stop_start)
cleanup_start = source.index("    private func finishCancelledCaptureOutput(")
cleanup_end = source.index("    private func stopCaptureWithoutOutputTask(", cleanup_start)
methods = source[stop_start:stop_end] + source[cleanup_start:cleanup_end]
methods = methods.replace("private func ", "func ").replace("PrivateProfileService.shared", "profiles")
Path(sys.argv[1]).write_text("import Foundation\n@MainActor extension ContentCaptureCallerHarness {\n" + methods + "}\n")

# These checks cover the large production processing method's original PCM handoff.
# Its decoding, UI and delivery dependencies are deliberately not linked into this suite.
processing_start = source.index("    private func processStoppedTranscription(", stop_end)
preserve = source.index("        func preserveConcealedCapture() -> Bool", processing_start)
preserve_call = source.index("        if preserveConcealedCapture() { return }", preserve)
empty_guard = source.index("        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else", preserve_call)
assert processing_start < preserve < preserve_call < empty_guard
assert "privateOutput?.preserveLocalResult(text: transcribedText, audio: audioSnapshot)" in source[preserve:preserve_call]
assert "if route.savesHistory" in source[preserve:preserve_call]
empty_end = source.index("        let cancelledAtASRStop", empty_guard)
assert 'if route.savesHistory { privateOutput?.preserveLocalResult(text: "", audio: audioSnapshot) }' in source[empty_guard:empty_end]
assert source.index("let audioSnapshot = self.asr.consumeLastCompletedAudioSnapshot()", processing_start) < preserve
print("Content capture PCM wiring: conceal preservation precedes the empty-result exit; original PCM reaches the existing output owner.")
PY_CALLER
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -O \
    -module-cache-path "$task_test_dir/module-cache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    Sources/Fluid/Services/Meeting/MeetingSummaryInput.swift \
    Sources/Fluid/Services/Meeting/PichiMeetingSummaryDocument.swift \
    Sources/Fluid/Services/FluidServe/FluidServeFileBoundary.swift \
    Sources/Fluid/Services/FluidServe/FluidServeMeetings.swift \
    Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationSource.swift \
    Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationPayload.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift \
    "$task_test_dir/AttributionTypes.swift" \
    Sources/Fluid/Services/Meeting/MeetingPersistenceValidation.swift \
    Sources/Fluid/Services/Meeting/MeetingSessionStore.swift \
    Sources/Fluid/Services/Meeting/MeetingAutomaticNaming.swift \
    Sources/Fluid/Services/Meeting/MeetingUniversalTitleEngine.swift \
    Sources/Fluid/Services/Meeting/MeetingSavedSummary.swift \
    Sources/Fluid/Services/Meeting/MeetingRecordingCipher.swift \
    Sources/Fluid/Services/Meeting/MeetingRecordingKeychainStore.swift Sources/Fluid/Persistence/ProtectedDataAccessError.swift \
    "$task_test_dir/PipelineVersion.swift" \
    Sources/Fluid/Account/AccountDomain.swift \
    Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileMeetingStore.swift \
    Sources/Fluid/Account/PrivateProfileService.swift \
    Sources/Fluid/Account/PrivateProfileOperationOwner.swift \
    Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift \
    Sources/Fluid/Services/Meeting/MeetingRetainedProcessingCheckpoint.swift \
    "$task_test_dir/ApplicationSupport.swift" Tests/MeetingSessionStoreCheckpointTests.swift \
    Tests/MeetingRecordingEncryptionTests.swift \
    Tests/MeetingAutomaticNamingTests.swift \
    Tests/MeetingLocalReaderDateTests.swift \
    Tests/MeetingTranscriptReadingContractTests.swift \
    Tests/MeetingProtectedTranscriptExportTests.swift \
    Tests/PichiProtectedPublicationSourceTests.swift \
    Tests/PrivateProfileMeetingStoreTests.swift \
    Tests/PrivateProfileLifecycleTests.swift \
    Tests/PrivateCaptureCallerWiringTests.swift "$task_test_dir/ContentCaptureCaller.swift" \
    Tests/PrivateProfileOperationOwnerTests.swift \
    -o "$task_test_dir/checkpoint-tests"
"$task_test_dir/checkpoint-tests" "$task_test_dir/fixtures-$(uuidgen)" "$@"
