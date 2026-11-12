#!/usr/bin/env python3
"""Model-free probe of real protected-tail, canonical policy and PCM assembly declarations.

The app-wide manifest/model adapters are not instantiated. Minimal external type aliases and
error cases support extracted production value declarations and complete PCM assembly methods.
"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build" / "streaming-protected-word-tail"
BUILD.mkdir(parents=True, exist_ok=True)
subprocess.run(["bash", "scripts/dev/assert-worktree.sh"], cwd=ROOT, check=True)


def declaration(text, name):
    start = text.index("nonisolated " + name)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end] + "\n"


meeting = ROOT / "Sources/Fluid/Services/Meeting"
models = (meeting / "MeetingModels.swift").read_text()
contracts = "import Foundation\n"
contracts += "typealias MeetingAudioTrackID = UUID\ntypealias SessionSpeakerID = UUID\n"
contracts += "typealias MeetingTranscriptSegmentID = UUID\n"
for name in ["enum MeetingAudioTrackKind", "enum MeetingTranscriptStatus", "enum MeetingTranscriptCompleteness",
             "enum MeetingTranscriptOverlap", "enum MeetingTranscriptAttributionState", "struct MeetingMediaTime",
             "struct MeetingIdentityCandidate", "struct MeetingSessionSpeaker", "struct MeetingSpeakerAttributionInference",
             "struct MeetingTranscriptSpeakerReference", "struct MeetingTranscriptSpeakerAttribution",
             "struct MeetingTranscriptNativeTiming", "struct MeetingTranscriptSegment"]:
    contracts += declaration(models, name)
contracts += declaration((meeting / "LiveTranscription/MeetingLiveModels.swift").read_text(), "struct MeetingLivePartial")
manifest = (meeting / "Backend/MeetingAnalysisManifest.swift").read_text()
contracts += declaration(manifest, "enum MeetingAnalysisManifestSchema")
contracts += declaration(manifest, "struct MeetingAnalysisInterval")
matcher = (meeting / "Backend/MeetingSpeakerVoiceMatcher.swift").read_text()
contracts += declaration(matcher, "struct MeetingSpeakerIdentityLink")
maximum = re.search(r"static let maximumProfiles = (\d+)", matcher).group(1)
contracts += "nonisolated enum MeetingSpeakerVoiceSamples { static let maximumProfiles = " + maximum + " }\n"
contracts += "nonisolated struct MeetingAudioTrack: Sendable {}\n"
contracts += "nonisolated enum MeetingParakeetNemotronRuntimeError: Error { case invalidPCMWindow }\n"
contracts += "nonisolated enum MeetingAssemblyError: Error { case invalidCoverageReceiptInterval(receiptID: String) }\n"
(BUILD / "ValueContracts.swift").write_text(contracts)
assembler = (meeting / "Backend/MeetingTranscriptAssembler.swift").read_text()
start = assembler.index("    private func makeSpeakers(")
pcm = "import Foundation\nimport CryptoKit\nnonisolated struct MeetingTranscriptAssembler {\n"
pcm += "    let speakerNameFormat: String\n"
pcm += "    init(speakerNameFormat: String) { self.speakerNameFormat = speakerNameFormat }\n"
for name in ["minimumSpeakerWords", "minimumSpeakerSeconds"]:
    pcm += re.search(r"^    static let " + name + r"[^\n]+", assembler, re.M).group(0) + "\n"
pcm += assembler[start:]
(BUILD / "PCMAssembly.swift").write_text(pcm)
subprocess.run([
    "xcrun", "swiftc", "-O", "-swift-version", "6", "-strict-concurrency=complete",
    "-default-isolation", "MainActor", "-parse-as-library", "-module-cache-path", str(BUILD / "ModuleCache"),
    str(ROOT / "Sources/Fluid/Localization/PichiLocalization.swift"),
    str(BUILD / "ValueContracts.swift"), str(meeting / "Backend/MeetingCanonicalEvidenceTypes.swift"),
    str(meeting / "Backend/MeetingSpeakerAttribution.swift"), str(meeting / "Backend/MeetingReadingSpeakerResolver.swift"), str(meeting / "MeetingPCMTranscriptBatch.swift"),
    str(BUILD / "PCMAssembly.swift"), str(meeting / "Backend/MeetingStreamingProtectedWordTail.swift"),
    str(ROOT / "Tests/MeetingStreamingProtectedWordTailTests.swift"), "-o", str(BUILD / "tests")
], cwd=ROOT, check=True)
subprocess.run([str(BUILD / "tests")], cwd=ROOT, check=True)
subprocess.run([
    "xcrun", "swiftc", "-O", "-swift-version", "6", "-strict-concurrency=complete",
    "-default-isolation", "MainActor", "-parse-as-library", "-module-cache-path", str(BUILD / "ModuleCache"),
    str(ROOT / "Sources/Fluid/Localization/PichiLocalization.swift"),
    str(BUILD / "ValueContracts.swift"), str(meeting / "Backend/MeetingCanonicalEvidenceTypes.swift"),
    str(meeting / "Backend/MeetingSpeakerAttribution.swift"), str(meeting / "Backend/MeetingReadingSpeakerResolver.swift"), str(meeting / "MeetingPCMTranscriptBatch.swift"),
    str(BUILD / "PCMAssembly.swift"), str(meeting / "Backend/MeetingStreamingProtectedWordTail.swift"),
    str(ROOT / "Tests/MeetingKnownSpeakerRegistryTests.swift"),
    "-o", str(BUILD / "registry-tests")
], cwd=ROOT, check=True)
subprocess.run([str(BUILD / "registry-tests")], cwd=ROOT, check=True)
subprocess.run([
    "xcrun", "swiftc", "-O", "-swift-version", "6", "-strict-concurrency=complete",
    "-default-isolation", "MainActor", "-parse-as-library", "-module-cache-path", str(BUILD / "ModuleCache"),
    str(ROOT / "Sources/Fluid/Localization/PichiLocalization.swift"),
    str(BUILD / "ValueContracts.swift"), str(meeting / "Backend/MeetingCanonicalEvidenceTypes.swift"),
    str(meeting / "Backend/MeetingSpeakerAttribution.swift"), str(meeting / "Backend/MeetingReadingSpeakerResolver.swift"), str(meeting / "MeetingPCMTranscriptBatch.swift"),
    str(BUILD / "PCMAssembly.swift"), str(meeting / "Backend/MeetingStreamingProtectedWordTail.swift"),
    str(ROOT / "Tests/MeetingVoicedSpeakerAdmissionTests.swift"), "-o", str(BUILD / "admission-tests")
], cwd=ROOT, check=True)
subprocess.run([str(BUILD / "admission-tests")], cwd=ROOT, check=True)

# Exercise the integration actor against the original privacy admission implementation.
# External native/resource orchestration is excluded, while privacy, models, speaker policy,
# word tail and the state actor are production source. The observation is inert runtime metadata.
def section(path, start, end):
    source = (ROOT / path).read_text()
    return source[source.index(start):source.index(end, source.index(start))]

full = "import Foundation\n"
# Tracing remains disabled and cannot follow the user's active private profile.
full += """
nonisolated struct PrivateProfileSnapshot: Sendable {
    let id = "synthetic-streaming-state"
    let generation: UUID
    let isReadable = false
    let isGuest = true
    func directory(_ component: String) -> URL { URL(fileURLWithPath: "/synthetic-streaming-state").appendingPathComponent(component) }
}
nonisolated enum PrivateProfileStorage {
    static let current = PrivateProfileSnapshot(generation: UUID())
}
"""
pipeline = (meeting / "MeetingProcessingPipeline.swift").read_text()
version = re.search(r"^    (?:nonisolated )?(static let pipelineVersion = [^\n]+)", pipeline, re.M).group(1)
full += "nonisolated enum MeetingProcessingPipeline { " + version + " }\n"
full += section("Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift",
                "nonisolated enum MeetingLiveSpeaker:", "nonisolated enum MeetingLiveTimeConversion")
full += section("Sources/Fluid/Services/Meeting/Backend/MeetingTranscriptionBackend.swift",
                "nonisolated struct MeetingBackendID:", "nonisolated enum MeetingBackendExecutionLocality:")
full += section("Sources/Fluid/Services/Meeting/Backend/MeetingBackendEvidence.swift",
                "nonisolated enum MeetingBackendEvidenceSchema", "nonisolated extension MeetingFinalTranscriptEvidence: Codable")
full += declaration(manifest, "enum MeetingAnalysisManifestSchema")
full += declaration(manifest, "struct MeetingAnalysisInterval")
full += declaration(matcher, "struct MeetingSpeakerIdentityLink")
full += "nonisolated enum MeetingSpeakerVoiceSamples { static let maximumProfiles = " + maximum + " }\n"
full += section("Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerVoiceMatcher.swift",
                "nonisolated struct MeetingSpeakerVoiceProfile:", "/// Explicit identity evidence across resets.")
full += "nonisolated enum MeetingParakeetNemotronRuntimeError: Error { case invalidPCMWindow }\n"
full += "nonisolated enum MeetingAssemblyError: Error { case invalidCoverageReceiptInterval(receiptID: String) }\n"
# Compile the actual observation contract so additive runtime metadata cannot drift.
full += declaration((meeting / "MeetingStreamingPCMController.swift").read_text(),
                    "struct MeetingStreamingPCMObservation")
full += declaration((meeting / "MeetingProcessingConfiguration.swift").read_text(), "struct MeetingFinalProcessingConfiguration")
full += """
nonisolated enum SettingsStore { enum SpeechModel: String { case synthetic } }
nonisolated enum MeetingProviderOptions {
    static func preferredModel(for language: String, selected: SettingsStore.SpeechModel?) -> SettingsStore.SpeechModel { .synthetic }
}
"""
(BUILD / "StreamingStateContracts.swift").write_text(full)
morphology = BUILD / "morphology"
subprocess.run(["swift", "build", "--package-path", str(ROOT / "Vendor/RussianMorphology"),
                "--scratch-path", str(morphology), "--jobs", "2"], cwd=ROOT, check=True)
products = morphology / "out/Products/Debug"
modulemap = morphology / "out/Intermediates.noindex/GeneratedModuleMaps/CRussianMorphology.modulemap"
state_command = [
    "xcrun", "swiftc", "-O", "-swift-version", "6", "-strict-concurrency=complete",
    "-default-isolation", "MainActor", "-parse-as-library", "-module-cache-path", str(BUILD / "ModuleCache"),
    "-I", str(products), "-L", str(products), "-lPichiRussianMorphology", "-lc++",
    "-Xcc", "-fmodule-map-file=" + str(modulemap),
    "-Xcc", "-I" + str(ROOT / "Vendor/RussianMorphology/Sources/CRussianMorphology/include"),
    str(BUILD / "StreamingStateContracts.swift"), str(ROOT / "Sources/Fluid/Localization/PichiLocalization.swift"),
    str(meeting / "MeetingModels.swift"), str(meeting / "MeetingSpeakerPresentation.swift"),
    str(meeting / "MeetingAudioAsset.swift"), str(meeting / "MeetingPersistedMetadata.swift"),
    str(meeting / "Backend/MeetingCanonicalEvidenceTypes.swift"), str(meeting / "Backend/MeetingSpeakerAttribution.swift"), str(meeting / "Backend/MeetingReadingSpeakerResolver.swift"),
    str(meeting / "MeetingPCMTranscriptBatch.swift"),
    str(ROOT / "Sources/Fluid/Services/Privacy/TranscriptTextRedacting.swift"),
    str(ROOT / "Sources/Fluid/Services/Privacy/TranscriptSensitiveDictionary.swift"),
    str(ROOT / "Sources/Fluid/Services/Privacy/SensitiveBusinessGroupCatalog.swift"),
    str(ROOT / "Sources/Fluid/Services/Privacy/SensitiveTopicClassifier.swift"),
    str(meeting / "MeetingTranscriptPrivacyPolicy.swift"),
    str(BUILD / "PCMAssembly.swift"), str(meeting / "Backend/MeetingStreamingProtectedWordTail.swift"),
    str(meeting / "MeetingTimelineTrace.swift"),
    str(meeting / "MeetingStreamingTranscriptState.swift"),
    str(ROOT / "Tests/MeetingStreamingTranscriptStateTests.swift"), "-o", str(BUILD / "state-tests")
]
subprocess.run(state_command, cwd=ROOT, check=True)
subprocess.run([str(BUILD / "state-tests")], cwd=ROOT, check=True)

provisional_command = [arg.replace("MeetingStreamingTranscriptStateTests.swift", "MeetingProvisionalSpeakerIdentityTests.swift")
                       .replace("state-tests", "provisional-tests") for arg in state_command]
subprocess.run(provisional_command, cwd=ROOT, check=True)
subprocess.run([str(BUILD / "provisional-tests")], cwd=ROOT, check=True)
