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
protocol = (repo / "Sources/Fluid/Services/TranscriptionProvider.swift").read_text()
progress = protocol[protocol.index("nonisolated enum ModelPreparationPhase:"):protocol.index("// MARK: - Transcription Result")]

with tempfile.TemporaryDirectory(prefix="pichi-gigaam-artifact-ownership-") as temporary:
    temporary = Path(temporary)
    runtime = temporary / "Runtime.swift"
    runtime.write_text((repo / "Tests/Support/GigaAMArtifactOwnershipRuntime.swift").read_text() + "\n" + error)
    library = temporary / "libPichiGigaAM.dylib"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-emit-module", "-emit-library",
        "-module-name", "PichiGigaAM", "-module-cache-path", str(temporary / "ModuleCache"),
        "-emit-module-path", str(temporary / "PichiGigaAM.swiftmodule"),
        str(catalog), str(runtime), "-o", str(library),
    ], check=True, cwd=repo)
    progress_source = temporary / "PreparationProgress.swift"
    progress_source.write_text("import Foundation\n" + progress)
    for isolation in ([], ["-default-isolation", "MainActor"]):
        executable = temporary / ("tests-main-actor" if isolation else "tests-default")
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-strict-concurrency=targeted",
            *isolation, "-module-cache-path", str(temporary / "ModuleCache"), "-I", str(temporary),
            "-L", str(temporary), "-lPichiGigaAM", "-Xlinker", "-rpath", "-Xlinker", str(temporary),
            str(provider), str(progress_source), str(repo / "Tests/GigaAMArtifactOwnershipTests.swift"),
            "-o", str(executable),
        ], check=True, cwd=repo)
        subprocess.run([str(executable), str(temporary / (executable.name + "-artifacts"))], check=True, cwd=repo, timeout=30)
print("GigaAM artifact ownership passed with both compiler isolation modes; temporary files removed.")
