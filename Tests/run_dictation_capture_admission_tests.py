#!/usr/bin/env python3
"""Exercise actual ASR admission declarations with inert synthetic providers."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
source = (repo / "Sources/Fluid/Services/ASRService.swift").read_text()
template = (repo / "Tests/DictationCaptureAdmissionTests.swift").read_text()

def between(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

actual = between("    private struct DictationTranscriptionAdmission", "    private var providerResetPending")
actual += between("    /// Synchronous admission freezes", "    private let audioCaptureReadinessGate")
actual += between("    private var transcriptionProvider: TranscriptionProvider", "    private func getGigaAMProvider()")
# The generated single source unit permits its tests to inspect the actual private state.
actual = actual.replace("    private ", "    ")
combined = template.replace("// ACTUAL_ASR_ADMISSION_SOURCE", actual)
protocol = (repo / "Sources/Fluid/Services/TranscriptionProvider.swift").read_text()
combined = combined.replace("// ACTUAL_TRANSCRIPTION_PROVIDER_SOURCE", protocol)

# These checks bind the runtime declarations to the production start/stop/readiness paths.
start = between("    func start(\n", "    func cancelPendingPronunciationTrainingStart()")
assert start.index("try self.admitDictationTranscription(captureLease)") < start.index("await ")
ensure = between("    func ensureAsrReady(\n        source:", "    private func modelArtifactsExist")
assert ensure.index("let dictationAdmission = self.dictationTranscriptionAdmission") < ensure.index("await ")
assert "dictationAdmission?.provider ?? self.transcriptionProvider" in ensure
assert "self.isTranscriptionSelectionCurrent(model: model, dictationLease: dictationAdmission?.lease)" in ensure
stop = between("    func stop(\n", "    private func beginDeferredStopUIInvalidation()")
assert "self.dictationFinalizationLease = stoppingLease" in stop
assert "self.finishDictationFinalization(stoppingLease)" in stop
assert "self.dictationTranscriptionAdmission?.retainHistoryAudio == true" in stop
recovery = between("    func finishStreamingDrainRecovery(sessionID: Int)", "// MARK: - Audio capture pipeline")
assert recovery.index("self.recordingBufferHandoffGate.complete(recovery.token)") < recovery.index("self.releaseDictationActivityIfNeeded(recovery.lease)")

with tempfile.TemporaryDirectory(prefix="pichi-dictation-admission-") as directory:
    directory = Path(directory)
    generated = directory / "AdmissionTests.swift"
    generated.write_text(combined)
    for mode in ([], ["-default-isolation", "MainActor"]):
        executable = directory / ("tests-actor" if mode else "tests-default")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-strict-concurrency=targeted", "-D", "DEBUG", *(["-D", "TEST_MAIN_ACTOR"] if mode else []), *mode, "-module-cache-path", str(directory / "ModuleCache"), str(repo / "Sources/Fluid/Services/ASRActivityLease.swift"), str(generated), "-o", str(executable)], check=True, cwd=repo)
        subprocess.run([str(executable)], check=True, cwd=repo)
print("ASR capture source wiring: 9 checks passed")
