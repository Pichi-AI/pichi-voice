#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/pii-policy-tests"
mkdir -p "$task_test_dir"
if [[ "${PICHI_PII_POLICY_ONLY:-0}" == "1" ]]; then
    if [[ -n "${PICHI_PII_TEST_MODEL_DIRECTORY:-}" || -n "${PICHI_PII_A1_TEST_MODEL_DIRECTORY:-}" ]]; then
        printf '%s\n' 'Policy-only tests cannot run an explicitly requested native model.' >&2
        exit 1
    fi
    # Compile actual pure detector sources without fetching or building ONNX Runtime.
    # The native span value is extracted unchanged; no inference implementation is stubbed.
    python3 - "$task_test_dir/NERSpan.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIINERRuntime.swift').read_text()
start = source.index('public struct PIINERSpan:')
end = source.index('struct PIIWordPrediction:', start)
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end])
PY
    xcrun swiftc -parse-as-library -swift-version 5 -O -emit-library -emit-module -module-name PichiTextPrivacy \
        -module-cache-path "$task_test_dir/module-cache" \
        -emit-module-path "$task_test_dir/PichiTextPrivacy.swiftmodule" \
        Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIIModelDescriptor.swift \
        Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIIWordPieceTokenizer.swift \
        Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIIRussianNameHeuristics.swift \
        Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIIRedactor.swift \
        Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIIProvisionalPreview.swift \
        "$task_test_dir/NERSpan.swift" -o "$task_test_dir/libPichiTextPrivacy.dylib"
    task_link_args=(-D PII_POLICY_STANDALONE -I "$task_test_dir" -L "$task_test_dir" -lPichiTextPrivacy \
        -Xlinker -rpath -Xlinker "$task_test_dir")
else
    bash Tests/run_transcript_privacy_tests.sh
    task_build_dir="$PWD/.build/pii-swiftpm"
    task_products="$task_build_dir/out/Products/Debug"
    task_frameworks="$task_build_dir/artifacts/onnxruntime-swift-package-manager/onnxruntime/onnxruntime.xcframework/macos-arm64_x86_64"
    task_link_args=(-I "$task_products" -L "$task_products" -lPichiTextPrivacy \
        -F "$task_frameworks" -framework onnxruntime -lc++ \
        -Xcc "-fmodule-map-file=$task_build_dir/out/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap" \
        -Xcc "-I$task_build_dir/checkouts/onnxruntime-swift-package-manager/objectivec/include" \
        -Xcc "-I$task_products/include" -Xlinker -rpath -Xlinker "$task_frameworks")
fi
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
source += Path('Sources/Fluid/Services/Meeting/Backend/MeetingCanonicalEvidenceTypes.swift').read_text()
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingBackendEvidence.swift', 'nonisolated enum MeetingBackendEvidenceSchema', 'nonisolated extension MeetingFinalTranscriptEvidence: Codable')
voice_source = Path('Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerVoiceMatcher.swift').read_text()
# The privacy batch references only this owner-declared metadata bound, never
# excerpt collection or inference. Extract its declaration instead of copying a value.
voice_bound = next(line for line in voice_source.splitlines() if line.strip().startswith('static let maximumProfiles ='))
source += 'nonisolated enum MeetingSpeakerVoiceSamples {\n' + voice_bound + '\n}\n'
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerVoiceMatcher.swift', 'nonisolated struct MeetingSpeakerVoiceProfile:', '/// Explicit identity evidence across resets.')
config = Path('Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift').read_text()
source += config[:config.index('/// Immutable value snapshot')]
Path(sys.argv[1]).write_text(source)
PY
task_morphology_dir="$PWD/.build/privacy-morphology"
swift build --package-path Vendor/RussianMorphology --scratch-path "$task_morphology_dir" --jobs 2
# SwiftPM's native Xcode layout puts the public module and static product here.
task_morphology_products="$task_morphology_dir/out/Products/Debug"
task_morphology_module="$task_morphology_dir/out/Intermediates.noindex/GeneratedModuleMaps/CRussianMorphology.modulemap"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -I "$task_morphology_products" -L "$task_morphology_products" -lPichiRussianMorphology -lc++ \
    -Xcc "-fmodule-map-file=$task_morphology_module" \
    -Xcc "-I$PWD/Vendor/RussianMorphology/Sources/CRussianMorphology/include" \
    -module-cache-path "$task_test_dir/module-cache" "${task_link_args[@]}" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingPCMTranscriptBatch.swift \
    Sources/Fluid/Services/Privacy/TranscriptTextRedacting.swift \
    Sources/Fluid/Services/Privacy/TranscriptSensitiveDictionary.swift \
    Sources/Fluid/Services/Privacy/SensitiveBusinessGroupCatalog.swift \
    Sources/Fluid/Services/Privacy/SensitiveTopicClassifier.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptPrivacyPolicy.swift \
    "$task_test_dir/EvidenceTypes.swift" Tests/MeetingPrivacyContextTests.swift Tests/TranscriptSensitiveDictionaryTests.swift \
    -o "$task_test_dir/privacy-context-tests"
"$task_test_dir/privacy-context-tests"
