#!/usr/bin/env python3
"""Exercise actual app residency observation/retirement with inert model dependencies."""
import argparse
import os
import signal
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def run(argv):
    process = subprocess.Popen(argv, cwd=ROOT, start_new_session=True)
    try:
        result = process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    if result:
        raise subprocess.CalledProcessError(result, argv)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref")
    args = parser.parse_args()
    path = "Sources/Fluid/Services/AppServices.swift"
    source = (subprocess.check_output(["git", "show", f"{args.baseline_ref}:{path}"], cwd=ROOT, text=True)
              if args.baseline_ref else (ROOT / path).read_text())
    refresh = declaration(source, "    func refreshLocalAIResidency(")
    profile_prepare = source.split("            }, prepare: { [weak self] in", 1)[1]
    profile_prepare = profile_prepare.split("                guard let self else { throw AccountError.isolationRequired }\n", 1)[1]
    profile_retirement = profile_prepare.split("                self._meetingAutoDetector?.stop()", 1)[0]
    shutdown = declaration(source, "    func shutdownForTermination()")
    termination_retirement = shutdown.split("        self.privateAIStartupWarmup = nil\n", 1)[1].split("        self._meetingAutoDetector?.stop()", 1)[0]
    properties = [line for line in source.splitlines() if line.strip().startswith((
        "private var _localAIModelResidency:", "private var localAIResidencySettingsObservation:",
        "private var localAIResidencySlot:", "private var cancellables ="))]
    helper = declaration(source, "    private func retireLocalAIResidency()") if "    private func retireLocalAIResidency()" in source else ""
    fixture = (ROOT / "Tests/LocalAIResidencyObservationTests.swift").read_text()
    marker = "// INSERT ACTUAL APP RESIDENCY METHODS"
    assert fixture.count(marker) == 1
    actual = "\n".join(properties) + "\n" + refresh + "\n" + helper
    actual += "\n    func prepareProfile() async {\n" + profile_retirement + "    }\n"
    actual += "\n    func terminate() async {\n        self.isTerminating = true\n" + termination_retirement + "    }\n"
    actual += "\n    var controller: LocalAIModelResidencyController? { self._localAIModelResidency }\n"
    with tempfile.TemporaryDirectory(prefix="pichi-residency-observation-", dir=ROOT / ".build") as directory:
        temporary = Path(directory)
        generated = temporary / "ActualMethods.swift"
        generated.write_text(fixture.replace(marker, actual))
        for label, flags in [("default", []), ("main-actor", ["-default-isolation", "MainActor"])]:
            binary = temporary / label
            run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", *flags,
                            "-module-cache-path", str(temporary / "ModuleCache"), str(generated), "-o", str(binary)])
            run([str(binary)])


if __name__ == "__main__":
    (ROOT / ".build").mkdir(exist_ok=True)
    main()
