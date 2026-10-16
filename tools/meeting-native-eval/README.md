# Native meeting evaluation

This optional offline command evaluates actual local meeting audio with the existing pinned
GigaAM INT8 runtime, fast32 W8A8 factory and shared Swift speaker attribution core. It does not
launch the application, change settings, request microphone access, enroll voices, download models
or contact a service. Audio, transcripts, model weights and output JSON stay in ignored local
storage. The CLI is an evaluation adapter, not another product processing pipeline.

Run `python3 tools/meeting-native-eval/test_batch_preflight.py` for six synthetic failure-path
checks. They validate that corpus changes, duplicate audio, reference replacement, insufficient
inputs and whole-meeting split leakage fail before native inference.

## Build prerequisites

Use a dedicated worktree. Supply these already available dependency artifacts in that worktree:

- `.build/SourcePackages/checkouts/FluidAudio` at `eb1e6628998e47022799d305b52c2680d3576801`.
- `.build/SourcePackages/checkouts/onnxruntime-swift-package-manager` at the application lockfile version.
- `.build/meeting-native-eval/dependencies/onnxruntime.framework`, a native macOS framework.
- `.build/meeting-native-eval/dependencies/OnnxRuntimeBindings.o`, the matching native bridge.

An APFS copy of immutable artifacts is sufficient. Never share a mutable package checkout,
DerivedData or output directory with another build. No dependency resolver runs here.

```sh
python3 tools/meeting-native-eval/build.py
```

The builder compiles production source files directly, including the shared canonical value file.
It extracts the remaining native runtime declarations verbatim. It also compiles
verbatim coverage and handoff helpers from production revision `448431f0` as a historical baseline.
Baseline handoff can cascade its previous assignment; the generalized core does not inherit that
behavior. GigaAM is compiled in a separate module with its original isolation default, so importing
it into an application with MainActor default isolation does not change the runtime's execution.
The generated build manifest records original source hashes, native bridge/runtime hashes and the
actual executable hash. Warnings from the pinned FluidAudio support source remain upstream warnings.

## One approved smoke clip

Use a regular mono 16kHz PCM16 WAV. Paths below are placeholders for authorized local inputs:

```sh
LLVM_PROFILE_FILE=/dev/null .build/meeting-native-eval/runner infer \
  /absolute/private/clip.wav /absolute/models/gigaam-v3-e2e-ctc-int8 \
  /absolute/models/fast32-w8a8.nemotronbundle \
  /absolute/private/clip.native.json clip-001 preferred
LLVM_PROFILE_FILE=/dev/null .build/meeting-native-eval/runner replay \
  /absolute/private/clip.native.json /absolute/private/clip.core.json
```

`preferred` uses the production compute policy. Other explicit native modes are `cpuAndGPU`,
`cpuAndNeuralEngine` and `cpuOnly`. Record the chosen mode and keep it fixed for a comparison.
The selected GigaAM descriptor verifies its own complete model/vocabulary checksums. Fast32's six
inference artifacts are pinned to the existing production bundle. Audio and artifacts are rehashed
before publication to detect replacement during inference.

Audio reads are bounded. ASR uses the stopped-meeting backend's 20-second core, 2-second context
and midpoint ownership schedule, calling the real GigaAM native runtime. Its CTC spans have 40ms
emission resolution and are approximate word times, not forced alignment. No words, alignment,
confidence, speaker names or temporal boundaries are fabricated. Each full clip gets one continuous
fresh fast32 state. The actual production interval decoder remains responsible for its activity
cadence and minimum segment length.

The evidence stores exact native text/times as unassigned source units, stable source IDs, scoped
anonymous activity tokens, historical baseline assignments, the separate initial common-core acoustic
projection, model pins and separate native timing/RSS measurements. No
relative embedding proposal is promoted into a known speaker identity. Each policy replay recomputes acoustic projection and final attribution from the unchanged source
units/activity without another model inference, and repeats both phases to verify
deterministic decisions. Raw source evidence and comparison outputs have separate ownership.

This command exercises actual model runtimes and the common attribution engine. It does not prove
application capture admission, canonical missing-audio manifest mapping, privacy UI, transcript
persistence, or physical iPad behavior. Mac peak process RSS excludes CoreML service allocations
and cannot be reported as iPad memory consumption.

## Frozen corpus

The private corpus manifest uses schema version 1 and `clips[]`. Each clip includes `clip_id`,
`meeting_id`, `split` (`development` or `heldOut`), absolute `audio_path`, `audio_sha256`,
`duration_seconds`, absolute `weak_reference_path`, `weak_reference_sha256`, and
`observed_weak_speaker_count`. Additional provenance fields may include source bounds, language,
recording ID and reference precision. Reference segments from automatic Fathom transcripts remain
weak evidence, without manually verified overlap or word times.

Before inference, freeze a separate JSON lock with `status: "frozen"` and
`corpus_manifest_sha256` equal to the manifest's actual SHA256. The batch preflight requires at
least 20 unique actual audio clips, 12 development and 8 held-out clips, no whole-meeting leakage,
at least five meetings and at least half the clips in the common two-speaker stratum. It validates
all audio formats, durations and audio/reference hashes before invoking a model.

```sh
python3 tools/meeting-native-eval/batch.py \
  --manifest /absolute/private/corpus.json \
  --selection-lock /absolute/private/selection-lock.json \
  --output /absolute/private/native-evaluation --pass-name baseline-development \
  --gigaam-directory /absolute/models/gigaam-v3-e2e-ctc-int8 \
  --fast32-directory /absolute/models/fast32-w8a8.nemotronbundle \
  --split development
```

Tune on development cases only. Use a new pass name and explicit frozen policy JSON to replay an
improvement. Open held-out results only after freezing the improved source/policy, then evaluate
`--split heldOut` in a new pass. Each pass stores its build, policy, input/output hashes, per-clip
completion and deterministic repeat result. Later passes reuse immutable native audio evidence;
that validates a postprocessing change, not a claim that repeated acoustic inference is identical.
Native inference is sequential and uses one process per clip, making peak process RSS comparable.
The first model load may include CoreML compilation/cache costs; report it separately from inference.

Name mappings used for comparison must be frozen from native activity once per clip and reused
across policies. Do not optimize a new mapping for each policy. Report acoustic activity agreement,
word attribution, unknown coverage, overlap and false merge/split evidence separately. Automatic
Fathom agreement is not human-ground-truth DER or a measured confidence calibration. Inspect actual
counterexamples before changing a policy; fewer unknown words alone does not establish better
speaker attribution.

## Weak-reference comparison

`score.py` imports the existing timeline evaluator's tested exact interval/collar and global
one-to-one assignment functions. It freezes one mapping from original native activity per
recording and reuses that mapping for the historical baseline and every policy. It never remaps
individual windows or tunes a mapping to make a policy appear better.

```sh
python3 tools/meeting-native-eval/test_weak_score.py
python3 tools/meeting-native-eval/score.py \
  --manifest /absolute/private/corpus.json \
  --native-directory /absolute/private/native-evaluation \
  --variant standard=/absolute/private/native-evaluation/baseline-development \
  --variant candidate=/absolute/private/native-evaluation/candidate-development \
  --split development --output /absolute/private/development-weak-analysis.json
```

The eight synthetic scorer oracles check unknown and assigned denominators, incorrect assigned
labels, undefined selective disagreement, exact collars, fixed mapping, interval duplication,
text-free diagnostic output and aggregate count weighting. The scorer validates frozen reference
hashes and original native evidence hashes before comparing policies.

Reports retain strict weak-reference and exact 1-second/2-second collar profiles. The collars
exclude both sides of canonical reference speaker TURN changes and clip edges, after adjacent
same-speaker phrases have been unioned. They are not only clip-edge filters. Whole native words
that cross excluded/unknown reference geometry stay unscored, and excluded counts plus all-native
word denominators remain explicit. No reference word timestamps are invented.

Native activity and word attribution are separate diagnostics. All automatic Fathom results remain
weak references, whose inferred turn ends include silence and whose single-speaker labels can omit
short simultaneous speech. An intended foreground-interrupter choice can therefore disagree with
Fathom's continuing main speaker. Such disagreement does not prove a diarization error. Unknown
coverage, weak agreement, weak disagreement and overlap policy must be assessed together.

An optional ASR edit diagnostic compares only complete, non-clipped automatic reference turns and
native words in their actual intervals. It is separate from speaker policy and remains a weak
text disagreement measure, not human-annotated WER. It excludes entire reference turns at clipped
window edges rather than inventing alignment or using their out-of-window text.
