#!/usr/bin/env python3
"""Exercise the actual GigaAM provider/store with inert runtime and temporary artifacts."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
provider = repo / "Sources/Fluid/Services/PichiGigaAMProvider.swift"
catalog = repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMModelCatalog.swift"
ctc = (repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMCTC.swift").read_text()
error = ctc[ctc.index("public enum GigaAMError:"):]
# 117: the provider converts GigaAMWordTiming (with its source context) into ASRWordTiming provenance.
# 174: the real GigaAMTranscript follows, since GigaAMWindowReuse.swift builds it; 175 reads its inferenceWork.
transcript_values = ctc[ctc.index("/// Exact inference input and word position"):ctc.index("struct GigaAMVocabulary:")]
# 174: the provider loads through PichiGigaAMInferenceRuntime with an explicit execution provider.
native_runtime = (repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMRuntime.swift").read_text()
execution_provider_start = native_runtime.index("public enum GigaAMExecutionProvider:")
execution_provider = native_runtime[execution_provider_start:native_runtime.index("\n}\n", execution_provider_start) + 3]
persisted = (repo / "Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift").read_text()
provenance_start = persisted.index("nonisolated struct ASRWordTimingProvenance:")
word_provenance = persisted[provenance_start:persisted.index("\n}\n", provenance_start) + 3]
protocol = (repo / "Sources/Fluid/Services/TranscriptionProvider.swift").read_text()
progress = protocol[protocol.index("nonisolated enum ModelPreparationPhase:"):protocol.index("// MARK: - Transcription Result")]
execution_status = protocol[protocol.index("nonisolated struct TranscriptionExecutionStatus:"):protocol.index("// MARK: - Transcription Provider Protocol")]
result_values = protocol[protocol.index("nonisolated struct ASRTranscriptionResult:"):protocol.index("/// The prepared execution policy")]
pronunciation = (repo / "Sources/Fluid/Services/PronunciationDictionaryStore.swift").read_text()
enrollment = pronunciation[pronunciation.index("nonisolated struct PronunciationEnrollmentCapture:"):pronunciation.index("nonisolated struct PronunciationDictionaryProfile:")]
native = (repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMCoreMLInference.swift").read_text()
runtime_status = native[native.index("public struct GigaAMExecutionStatus:"):native.index("/// The shipped Core ML graph")]

def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(signature)


neighbors = (repo / "Tests/Support/GigaAMArtifactDictionaryNeighbors.swift").read_text()
acoustics = (repo / "Sources/Fluid/Services/GigaAMDictionaryAcoustics.swift").read_text()
encoder = (repo / "Sources/Fluid/Services/GigaAMEncoderDictionaryStorage.swift").read_text()
neighbors = neighbors.replace("// ACTUAL_LEGACY_MODEL_KEY", method(acoustics, "    static func modelKey("))
neighbors = neighbors.replace("// ACTUAL_ENCODER_MODEL_KEY", method(encoder, "    private static var keyPrefix:") + "\n" + method(encoder, "    static func modelKey("))
# 175: final correction counts retryable reference diagnostics of the real preparation result.
encoder_dictionary = (repo / "Sources/Fluid/Services/GigaAMEncoderDictionary.swift").read_text()
neighbors = neighbors.replace("// ACTUAL_ENCODER_PREPARATION", "\n".join(method(encoder_dictionary, signature)
    for signature in ("    enum Reason:", "    struct Diagnostic:", "    struct Preparation:")))

with tempfile.TemporaryDirectory(prefix="pichi-gigaam-artifact-ownership-") as temporary:
    temporary = Path(temporary)
    runtime = temporary / "Runtime.swift"
    runtime.write_text((repo / "Tests/Support/GigaAMArtifactOwnershipRuntime.swift").read_text() + "\n" + error + "\n" + runtime_status + "\n" + transcript_values + "\n" + execution_provider)
    library = temporary / "libPichiGigaAM.dylib"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-emit-module", "-emit-library",
        "-module-name", "PichiGigaAM", "-module-cache-path", str(temporary / "ModuleCache"),
        "-emit-module-path", str(temporary / "PichiGigaAM.swiftmodule"),
        str(catalog), str(repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMResourcePolicy.swift"),
        str(repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMFrontend.swift"),
        str(repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMAcousticFeatures.swift"),
        str(repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMEncoderFeatures.swift"),
        str(repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMAcousticMatcher.swift"),
        # 174: the provider owns GigaAMWindowReuseSession handles and reads GigaAMTranscriptionWork.
        str(repo / "Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMWindowReuse.swift"), str(runtime), "-o", str(library),
    ], check=True, cwd=repo)
    progress_source = temporary / "PreparationProgress.swift"
    progress_source.write_text("import Foundation\n" + progress + "\n" + execution_status + "\n" + result_values + "\n" + enrollment + "\n" + word_provenance)
    neighbor_source = temporary / "DictionaryNeighbors.swift"
    neighbor_source.write_text(neighbors)
    for isolation in ([], ["-default-isolation", "MainActor"]):
        executable = temporary / ("tests-main-actor" if isolation else "tests-default")
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-strict-concurrency=targeted",
            *isolation, "-module-cache-path", str(temporary / "ModuleCache"), "-I", str(temporary),
            "-L", str(temporary), "-lPichiGigaAM", "-Xlinker", "-rpath", "-Xlinker", str(temporary),
            str(provider), str(progress_source),
            str(repo / "Sources/Fluid/Services/DictionaryAudioInspection.swift"),
            str(repo / "Sources/Fluid/Services/DictionaryLearningEvidence.swift"),
            # DictionaryLearningEvidence validates correction ranges through the 101 replacement plan.
            str(repo / "Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift"),
            str(neighbor_source),
            str(repo / "Tests/GigaAMArtifactOwnershipTests.swift"),
            "-o", str(executable),
        ], check=True, cwd=repo)
        subprocess.run([str(executable), str(temporary / (executable.name + "-artifacts"))], check=True, cwd=repo, timeout=30)
print("GigaAM artifact ownership passed with both compiler isolation modes; temporary files removed.")
