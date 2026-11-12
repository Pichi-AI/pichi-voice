#!/usr/bin/env python3
"""Copy the actual capture-clock value contracts that MeetingPCMSourceTimeline.swift and the PCM transport name.

MeetingModels.swift owns them beside the whole session model, which bounded capture probes do not link.
The block is contiguous and self-contained: media time, recording time policy, clock span, mapping and timebase.
"""
from pathlib import Path
import sys

source = Path("Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text()
begin_marker = "nonisolated struct MeetingMediaTime:"
end_marker = "nonisolated struct MeetingAudioFormat:"
assert source.count(begin_marker) == 1 and source.count(end_marker) == 1, "Expected one production declaration per boundary"
begin, end = source.index(begin_marker), source.index(end_marker)
assert begin < end, "Capture-clock value contracts must precede the audio format"
# A caller that already declares the track identifier alias passes --without-track-id.
# --with-recording-clocks also copies the clock owner, source context and source clock.
track_id = "" if "--without-track-id" in sys.argv else next(
    line for line in source.splitlines() if line.startswith("typealias MeetingAudioTrackID =")) + "\n"
text = "import CoreMedia\nimport Foundation\nimport CryptoKit\n" + track_id + source[begin:end]
if "--with-recording-clocks" in sys.argv:
    # The recording clock owner, its per-source context and the source clock live beside the live-transcription models.
    live = Path("Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift").read_text()
    for marker in ("final nonisolated class MeetingRecordingClock:", "nonisolated struct MeetingRecordingClockContext:",
                   "final nonisolated class MeetingCaptureSourceClock:"):
        assert live.count(marker) == 1, f"Expected one production declaration of {marker}"
        start = live.index(marker)
        opening = live.index("{", start)
        depth, index = 1, opening + 1
        while depth:
            depth += (live[index] == "{") - (live[index] == "}")
            index += 1
        text += "\n" + live[start:index] + "\n"
Path(sys.argv[1]).write_text(text)
