#!/usr/bin/env python3
"""Extract unchanged canonical value contracts for bounded production-code tests."""
from pathlib import Path
import sys

output = Path(sys.argv[1])
source = Path("Sources/Fluid/Services/Meeting/Backend/MeetingBackendEvidence.swift").read_text()
values = source[:source.index("nonisolated struct MeetingFinalTranscriptEvidence:")]
values += "\nnonisolated extension MeetingFinalTextUnit: Codable {}\n"
values += "nonisolated extension MeetingBackendSpeakerActivity: Codable {}\n"
if "--fingerprint" in sys.argv[2:]:
    config = Path("Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift").read_text()
    values += config[:config.index("/// Immutable value snapshot")]
output.write_text(values)
