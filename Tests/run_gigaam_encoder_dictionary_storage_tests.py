#!/usr/bin/env python3
"""Compile the complete storage bridge with real feature/calibration code and inert storage."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent


def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if not depth:
            return source[start:index + 1]
    raise ValueError(signature)


store = (root / "Sources/Fluid/Services/PronunciationDictionaryStore.swift").read_text()
acoustic = (root / "Sources/Fluid/Services/GigaAMDictionaryAcoustics.swift").read_text()
negative = (root / "Sources/Fluid/Services/DictionaryNegativeExamples.swift").read_text()
experiment = (root / "Sources/Fluid/Services/DictionaryPronunciationExperiment.swift").read_text()
types = store[store.index("nonisolated struct PronunciationEnrollmentCapture:"):store.index("actor PronunciationDictionaryStore")]
projection = "import Foundation\nimport CryptoKit\n" + types
projection += "\nnonisolated enum GigaAMDictionaryAcoustics {\n" + method(acoustic, "    struct Snapshot:")
projection += "\n" + method(acoustic, "    static func activeCaptures(") + "\n}\n"
projection += "\nnonisolated enum DictionaryNegativeEvidenceResolver {\n" + method(negative, "    static func profileKey(") + "\n}\n"
projection += "\nnonisolated enum DictionaryPronunciationExperiment {\n" + method(experiment, "    static func trimmedRange(") + "\n}\n"
test = (root / "Tests/Standalone/GigaAMEncoderDictionaryStorageTests.swift").read_text()
test = test.replace("// ACTUAL_MATCHING_ENROLLMENTS", method(store, "    static func matchingEnrollments("))
(root / ".build").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="encoder-storage-", dir=root / ".build") as temporary:
    temporary = Path(temporary)
    cache = temporary / "ModuleCache"
    package = root / "Vendor/PichiGigaAM/Sources/PichiGigaAM"
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-emit-library", "-emit-module", "-module-name", "PichiGigaAM",
                    "-module-cache-path", str(cache), "-emit-module-path", str(temporary / "PichiGigaAM.swiftmodule"),
                    *[str(package / name) for name in ["GigaAMFrontend.swift", "GigaAMAcousticFeatures.swift", "GigaAMEncoderFeatures.swift", "GigaAMAcousticMatcher.swift", "GigaAMCTC.swift"]],
                    "-o", str(temporary / "libPichiGigaAM.dylib")], check=True, cwd=root)
    projected = temporary / "Policies.swift"; projected.write_text(projection)
    tests = temporary / "StorageTests.swift"; tests.write_text(test)
    sources = ["GigaAMEncoderDictionaryStorage.swift", "GigaAMEncoderDictionary.swift", "GigaAMDictionaryLexicalEvidence.swift",
               "DictionaryAudioInspection.swift", "DictionaryLearningEvidence.swift", "DictionaryAudioSpan.swift",
               "DictionaryStampMatcher.swift", "DictionaryReplacementProtection.swift"]
    for isolation in ([], ["-default-isolation", "MainActor"]):
        executable = temporary / ("tests-main-actor" if isolation else "tests-default")
        subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library", "-D", "GIGAAM_ENCODER_STORAGE_STANDALONE",
                        *isolation, "-module-cache-path", str(cache), "-I", str(temporary), "-L", str(temporary), "-lPichiGigaAM",
                        "-Xlinker", "-rpath", "-Xlinker", str(temporary), str(projected), str(tests),
                        *[str(root / "Sources/Fluid/Services" / name) for name in sources], "-o", str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True, cwd=root, timeout=30)
print("Encoder storage bridge temporary build resources removed.")
