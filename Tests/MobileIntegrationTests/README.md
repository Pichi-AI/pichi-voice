# Opt-in combined Russian meeting probe

Physical runtime tests retain one native screen frame per second with
`scripts/dev/capture-mobile-frames.py --device <UDID> --revision <tested-SHA> --test-case <name> --output <ignored-directory>`.
The helper keeps every frame and separate changed/unique decoded-pixel indexes, reports missed
seconds and never invokes a camera or microphone. A `STOP` file in the output directory ends it.
Use `--platform simulator` for simulator UI tests. Frame capture is part of measurement overhead.

For private detailed streaming E2E, `PICHI_MEETING_RENDER_LIVE_E2E=1` mounts the production
meeting root with the exact isolated inference coordinator in a test-owned foreground window.
It restores the former key window on exit. Without this opt-in, an idle shared app interface
does not measure the test pipeline's live rendering load. One-second images and MainActor
queue samples do not by themselves measure physical touch/scroll latency or rendered FPS.

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

For an explicitly requested private visual review, the additional simulator-only
`PICHI_COMBINED_MEETING_EXPORT_PRIVATE_REVIEW=1` gate attaches the actual protected
transcript segments and speakers. This contains user text: keep the result bundle
and any derived HTML in ignored private storage. Physical probes ignore this gate.
This is a fresh simulator replay and must never be presented as recovered text or
speaker intervals from an earlier metadata-only physical-device run.


## Existing owner reference: private scalar comparison

Select only `PichiVoiceMobileIntegrationTests/MobileOwnerVoiceComparisonTests/testPrivateExistingOwnerVoiceScalarComparison` after freezing the exact build. The mobile project generator includes this file directly in the hosted iOS integration target. This test reads the current enrolled reference and a caller-reviewed, single-voice task fixture at `audio/combined-ru.wav`; it never saves, deletes or replaces a voice profile. Run the known-positive source and independently reviewed negative voices separately under the same preserved reference. Parent device orchestration must verify the exact selected test executed once and preserve the current user container and task fixture before installation.

Required gates are `PICHI_OWNER_VOICE_PRIVATE_DIAGNOSTIC=1`, `PICHI_COMBINED_MEETING_PRIVATE_EVALUATION=1`, `PICHI_COMBINED_MEETING_E2E=1`, and `PICHI_MEETING_DETAILED_PROFILE=1`. Set `PICHI_OWNER_VOICE_DIAGNOSTIC_AUDIO_SHA256` to the exact staged audio digest, `PICHI_MOBILE_INFERENCE_ASSETS=application-support`, and optionally `PICHI_OWNER_VOICE_DIAGNOSTIC_SOURCE_FRAMES` (default 320000; accepted 102400 through 320000). The input must be bounded mono16k audio. No microphone, ASR, speaker graph or installer runs. The existing audio lease and model residency scope exclude other inference while the voice encoder runs on its joined executor.

The private attachment `PrivateOwnerVoiceScalarComparison.json` contains only typed numerical/boolean diagnostics: source/query RMS, centered RMS, range, clipping, sample counts, 2x2 self/cross cosine distances, current thresholds, verification counts and encoding time. No embeddings, names, profile generation, audio, paths, source hashes or transcript text are attached. The original enrollment audio is unavailable, so the report cannot infer its RMS, clipping or recorded duration. A test pass means the comparison ran safely; the reported verification result can still be a false negative requiring investigation.

| Variant ID | Comparison |
| --- | --- |
| 0 | Actual streaming collector, two clean3s clips under an explicitly assumed whole-fixture single voice |
| 1 | Existing enrollment/offline collector from the same source, typically two5s clips |
| 2 | Later independent3s clips, when the source is long enough |
| 3 | Two disjoint9s clips, when the source is long enough |
| 4 | Variant0 with bounded RMS normalization, diagnostic only |
| 5 | Variant0 with its DC mean removed, diagnostic only |
| 6 | Exact variant0 repeated in the same encoder load, numerical-repeatability control |
| 7 | First and last disjoint5s clips, each inset160ms, when at least10.32s of input exists |
| 8 | First and last disjoint3s clips, each inset160ms |

The production diarizer's actual clean ranges are not replayed in this isolated comparison. Differences between variants can reveal duration/content/channel sensitivity but do not establish speaker accuracy. `sameSourceEarlyReferenceConfirmedCount` uses variant0 embeddings as an in-memory control and never replaces the real enrolled reference. For one query candidate the ambiguity margin has no observed competitor; the report marks that margin unavailable. Keep the fixed production threshold and require multiple independent negative controls before adopting a generic change. Compare a same-channel current microphone observation against the stored reference to distinguish a poor enrollment from meeting-codec or microphone channel shift; that observation requires the actual owner's voice and must not be simulated as a positive result.


For a concurrent CPU-only run on an iOS Simulator, the same test accepts `PICHI_OWNER_VOICE_DIAGNOSTIC_PROFILE_PATH` as an explicit absolute read-only host path under all existing private opt-ins. It does not copy that reference into the simulator's application profile. Physical builds reject this override. Stage the pinned public voice model in the simulator's normal application model cache using the existing artifact contract; no product model-selection override exists. Point the existing `PICHI_MOBILE_INFERENCE_ASSETS` at one ignored case directory containing `audio/combined-ru.wav`. Profile paths and contents are never attached. `externalReadOnlySimulatorReference` distinguishes this comparison from the physical app's default reference.

The historical `duplicateEncodingDistance` is the complete-link maximum over all four pairs, so identical repeated two-clip profiles can still have a nonzero value. The added `duplicateEncodingMatchedMaximumDistance` compares corresponding clips, and `duplicateEncodingMaximumAbsoluteDifference` reports only the largest numerical difference between corresponding vector components. These scalar fields assess repeatability without exporting vectors. A simulator run measures the Mac CPU implementation of the same iOS encoder path; its timing is not iPad performance evidence.
