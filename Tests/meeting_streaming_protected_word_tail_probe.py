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
    str(BUILD / "ValueContracts.swift"), str(meeting / "Backend/MeetingCanonicalEvidenceTypes.swift"),
    str(meeting / "Backend/MeetingSpeakerAttribution.swift"), str(meeting / "MeetingPCMTranscriptBatch.swift"),
    str(BUILD / "PCMAssembly.swift"), str(meeting / "Backend/MeetingStreamingProtectedWordTail.swift"),
    str(ROOT / "Tests/MeetingStreamingProtectedWordTailTests.swift"), "-o", str(BUILD / "tests")
], cwd=ROOT, check=True)
subprocess.run([str(BUILD / "tests")], cwd=ROOT, check=True)
