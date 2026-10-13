#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash Tests/run_transcript_privacy_tests.sh
task_build_dir="$PWD/.build/pii-swiftpm"
task_test_dir="$PWD/.build/pii-policy-tests"
mkdir -p "$task_test_dir"
# Compile the owning model types unchanged, excluding unrelated validation/
# inference orchestration. No duplicated segment/timestamp/policy implementation.
python3 - "$task_test_dir/EvidenceTypes.swift" <<'PY'
from pathlib import Path
import sys
def section(path, start, end):
    text = Path(path).read_text()
    return text[text.index(start):text.index(end, text.index(start))]
source = 'import Foundation\n'
source += section('Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift', 'nonisolated enum MeetingLiveSpeaker:', 'nonisolated enum MeetingLiveTimeConversion')
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingTranscriptionBackend.swift', 'nonisolated struct MeetingBackendID:', 'nonisolated enum MeetingBackendExecutionLocality:')
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingBackendEvidence.swift', 'nonisolated enum MeetingBackendEvidenceSchema', 'nonisolated extension MeetingFinalTextUnit: Codable')
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerVoiceMatcher.swift', 'nonisolated struct MeetingSpeakerVoiceProfile:', '/// Explicit identity evidence across resets.')
source += section('Sources/Fluid/Services/Meeting/MeetingPostProcessing.swift', 'nonisolated struct MeetingPostProcessingOutput:', '/// The prepared scope')
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingResultSidecarStore.swift', 'nonisolated struct MeetingResultSidecarReference:', 'nonisolated enum MeetingResultSidecarStoreError:')
Path(sys.argv[1]).write_text(source)
PY
task_products="$task_build_dir/out/Products/Debug"
task_frameworks="$task_build_dir/artifacts/onnxruntime-swift-package-manager/onnxruntime/onnxruntime.xcframework/macos-arm64_x86_64"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -I "$task_products" -L "$task_products" -lPichiTextPrivacy \
    -F "$task_frameworks" -framework onnxruntime -lc++ \
    -Xcc "-fmodule-map-file=$task_build_dir/out/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap" \
    -Xcc "-I$task_build_dir/checkouts/onnxruntime-swift-package-manager/objectivec/include" \
    -Xcc "-I$task_products/include" -Xlinker -rpath -Xlinker "$task_frameworks" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingMicrophoneCaptureContracts.swift \
    Sources/Fluid/Services/Meeting/MeetingPCMTranscriptBatch.swift \
    Sources/Fluid/Services/Privacy/TranscriptTextRedacting.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptPrivacyPolicy.swift \
    "$task_test_dir/EvidenceTypes.swift" Tests/MeetingPrivacyContextTests.swift \
    -o "$task_test_dir/privacy-context-tests"
"$task_test_dir/privacy-context-tests"
