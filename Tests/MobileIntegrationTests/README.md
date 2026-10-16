# Opt-in combined Russian meeting probe

Run `MobileMeetingEndToEndTests/testCombinedRussianMeetingPrivacySpeakersAndFootprint`
only after building the integrated mobile test host. The parent testing session owns
simulator and physical-device execution, installation, signing, and user review.
This test performs no UI automation and does not request microphone access.

Required test-host environment:

```text
PICHI_COMBINED_MEETING_E2E=1
PICHI_MOBILE_INFERENCE_ASSETS=application-support
PICHI_COMBINED_MEETING_TESTED_REVISION=<exact frozen build commit>
```

An absolute asset directory is also accepted on a simulator. `application-support`
resolves the existing `MobileInferenceAssets` directory in the current app container.
Without the combined gate, the test skips before opening audio or preparing models.
The ordinary service preparation operations may install missing public model files;
stage them first when network-free execution is required. ASR and diarization use
their normal stores; privacy uses `models/privacy` beneath the staged asset root.
The probe asserts A1 and fast32 identities. ASR defaults to Whisper Tiny; set optional
`PICHI_COMBINED_MEETING_ASR` to an existing registered speech-model identifier, such
as `gigaam-v3-eou`, to evaluate the same composition with that engine. Unknown or
unsupported identifiers fail before model work. The selected identity is fixed for
the attempt, asserted against every completed attempt and included in the metadata.
This setting affects only isolated probe preferences, not the user's selected model.

Stage these two private files, never commit personal fixtures:

- `audio/combined-ru.wav`: mono 16 kHz Float32-readable PCM WAV, 10 to 600 seconds,
  at most 64 MiB. Prefer at least 60 seconds, two distinct speakers with multiple
  turns and at least five seconds of usable voice evidence per person. No overlap
  is supported in this small reference scorer.
- `audio/combined-ru-reference.json`: at most 128 KiB, with the schema below.

```json
{
  "provenance": "synthetic",
  "turns": [
    {"start": 1.0, "end": 13.0, "speaker": 0},
    {"start": 15.0, "end": 28.0, "speaker": 1}
  ],
  "sensitiveAliases": [
    ["ivan.test@example.org", "ivan точка test собака example точка org"],
    ["Demo123!"]
  ],
  "textAnchors": ["обсудим документ", "проверим результаты"]
}
```

The example describes a schema, not an existing waveform or a gold annotation.
For approved personal audio use `human-reviewed` provenance. A person must review
speech intervals, speaker identities, harmless Russian text anchors, and sensitive
source values. Freeze that reference before evaluating candidate privacy results.
Aliases describe recognized spellings of one source entity, not fabricated contact
reconstruction. Use 2 to 6 speakers, 2 to 512 ordered non-overlapping speech turns,
1 to 64 sensitive cases, and 2 to 32 harmless anchors. References with missing or
weak speaker gold cannot establish diarization quality; do not label them reviewed.
For existing Fathom starts without reviewed ends, set `provenance` to
`weak-fathom`. This mode reports approximate assignment and unscored ASR cases;
it does not apply the complete-quality assertions or turn a passing execution
test into proof of speaker accuracy or complete redaction. It still requires
Russian transcription and at least one source anchor; all anchor misses remain
reported. Actual observed leaks and failed storage invariants still fail the probe.

The actual shared AppServices, coordinator, pipeline, model preparation, speaker
matching, privacy and strict storage run behind the existing capture seam. File
reads and PCM delivery are bounded to 100 ms, paced at real time. This verifies
inference composition and backpressure, not acoustic capture, background execution,
thermal behavior or energy use.

The private XCTest attachment contains only hashes, model lineage, counts and
resource samples. It contains no input text, transcript, aliases or reference turns.
Footprint samples cover preparation, ready privacy, capture, post-stop processing,
completed privacy and joined cleanup at a nominal 250 ms cadence. They measure
this process only, can miss transient peaks and exclude external Core ML daemons.
The baseline and cleanup delta include runtime/ASR caching, so they do not establish
a leak or prove that all model memory was freed. Set optional
`PICHI_COMBINED_MEETING_MAX_FOOTPRINT_MIB` for an explicit whole-process budget.

For synthetic or human-reviewed references, quality requires nonempty Russian ASR,
all harmless anchors, at least 80% reference
speaker-time assignment after a global one-to-one label permutation, and actual
privacy spans covering all letters/digits of expected recognized sensitive values.
Missing ASR values are counted as unscored and fail the complete-quality gate.
Unmasked publishable observations and remaining source aliases also fail it.
Speaker-time agreement uses final transcript intervals and a 100 ms grid; it is not
acoustic DER, WER, overlap accuracy or a general Russian-language benchmark.
