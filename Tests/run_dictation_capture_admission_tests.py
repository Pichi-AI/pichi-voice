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

actual = between("    private struct AdmittedTranscription", "    private var providerResetPending")
actual += between("    /// Pin the existing provider", "    private let audioCaptureReadinessGate")
actual += between("    private var transcriptionProvider: TranscriptionProvider", "    private func getGigaAMProvider()")
actual += between("    func beginStreamingDrainRecovery(sessionID: Int", "\n}\n\n// MARK: - Audio capture pipeline")
# The generated single source unit permits its tests to inspect the actual private state.
actual = actual.replace("    private ", "    ")
combined = template.replace("// ACTUAL_ASR_ADMISSION_SOURCE", actual)
protocol = (repo / "Sources/Fluid/Services/TranscriptionProvider.swift").read_text()
evidence = (repo / "Sources/Fluid/Services/DictionaryLearningEvidence.swift").read_text()
def declaration(marker, text=evidence):
    assert text.count(marker) == 1, f"Expected one production declaration of {marker}"
    begin = text.index(marker)
    end = text.index("{", begin) + 1
    depth = 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[begin:end]

# 117 gave ASRWordTiming a timing provenance that TranscriptionProvider.swift now names.
persisted = (repo / "Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift").read_text()
timing_provenance = declaration("nonisolated struct ASRWordTimingProvenance:", persisted) + "\n"

# The evidence transport carries feature windows; their frame payload type is inert here.
frames_stub = "nonisolated struct DictionaryAudioInspection { struct Frames: Equatable, Sendable {} }\n"
audio_evidence = timing_provenance + frames_stub + declaration("nonisolated struct DictionaryLearningFeatureFrames:") + "\n" + declaration("nonisolated struct DictionaryLearningAudioEvidence:")
combined = combined.replace("// ACTUAL_TRANSCRIPTION_PROVIDER_SOURCE", audio_evidence + "\n" + protocol)

# These checks bind the runtime declarations to the production start/stop/readiness paths.
start = between("    func start(\n", "    func cancelPendingPronunciationTrainingStart()")
# start() suspends only inside acquireForegroundActivity. After that it revalidates and admits without
# another suspension, so a start that went stale while waiting for the lease cannot reach admission.
acquire = "captureLease = try await self.acquireForegroundActivity(.dictation)"
admit = "try self.admitDictationTranscription(captureLease)"
assert start.count(acquire) == 1 and start.count(admit) == 1
assert start.index("await ") == start.index(acquire) + len("captureLease = try ")
assert start.index(acquire) < start.index("startGeneration == self.audioCaptureStartGeneration, !self.isTerminating") < start.index(admit)
for condition in ("!Task.isCancelled", "self.isPronunciationTrainingStartCurrent", "PrivateProfileStorage.acceptsNewWork",
                  "PrivateProfileStorage.isReadable(profile)", "PrivateProfileStorage.current == profile",
                  "self.releaseExclusiveActivity(captureLease)"):
    assert condition in start[start.index(acquire):start.index(admit)], condition
assert "await " not in start[start.index(acquire) + len(acquire):start.index(admit)]
ensure = between("    func ensureAsrReady(\n        source:", "    private func modelArtifactsExist")
assert ensure.index("let transcriptionAdmission = self.admittedTranscription") < ensure.index("await ")
assert "transcriptionAdmission?.provider ?? self.transcriptionProvider" in ensure
assert "self.isTranscriptionSelectionCurrent(model: model, admittedLease: transcriptionAdmission?.lease)" in ensure
stop = between("    func stop(\n", "    private func beginDeferredStopUIInvalidation()")
assert "self.beginDictationFinalization(stoppingLease)" in stop
assert stop.index("guard self.dictationFinalizationID == nil") < stop.index("self.lastStopOutcome = .empty")
assert "retainAudio: self.admittedTranscription?.automaticLearning == true" in stop
assert "!PrivateProfileStorage.isReadable(admission.profile)" in stop
assert "self.finishDictationFinalization(stoppingLease, id: finalizationID)" in stop
assert "self.admittedTranscription?.retainHistoryAudio == true" in stop
timeout = stop[stop.index("guard await self.drainActiveStreamingWork"):stop.index('self.benchmarkLog("stop_streaming_wait')]
assert timeout.index("self.retainAdmittedCaptureAudio(self.audioBuffer.getAll())") < timeout.index("self.beginStreamingDrainRecovery") < timeout.index('return ""')
recovery = between("    func finishStreamingDrainRecovery(sessionID: Int)", "// MARK: - Audio capture pipeline")
assert recovery.index("self.recordingBufferHandoffGate.complete(recovery.token)") < recovery.index("self.releaseDictationActivityIfNeeded(recovery.lease)")

with tempfile.TemporaryDirectory(prefix="pichi-dictation-admission-") as directory:
    directory = Path(directory)
    profile_types = directory / "ProfileTypes.swift"
    subprocess.run(["python3", "-S", "Tests/Support/write_private_profile_standalone_types.py", str(profile_types), "--archive-carriers"], check=True, cwd=repo)
    generated = directory / "AdmissionTests.swift"
    generated.write_text(combined)
    for mode in ([], ["-default-isolation", "MainActor"]):
        executable = directory / ("tests-actor" if mode else "tests-default")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-strict-concurrency=targeted", "-D", "DEBUG", *(["-D", "TEST_MAIN_ACTOR"] if mode else []), *mode, "-module-cache-path", str(directory / "ModuleCache"), str(profile_types), str(repo / "Sources/Fluid/Account/PrivateProfileStorage.swift"), str(repo / "Sources/Fluid/Services/ASRActivityLease.swift"), str(repo / "Sources/Fluid/Services/ThreadSafeAudioBuffer.swift"), str(generated), "-o", str(executable)], check=True, cwd=repo)
        subprocess.run([str(executable)], check=True, cwd=repo)
print("ASR capture source wiring passed")
