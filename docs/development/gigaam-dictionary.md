# GigaAM acoustic dictionary

GigaAM dictionary references remain local audio examples, not updated model
weights. The provider binds every example to the model fingerprint and extractor
recipe. Existing correction capture, pronunciation storage and admitted profile
reads carry the original PCM and optional features from the same ASR pass.

A compatible GGUF runtime supplies bounded 768-channel encoder features at a
40 ms clock. Matching calibrates its operating point from the active references
and other enrolled terms. A confirmed contextual correction complements two
other recordings through the existing `activeCaptures` selection; older examples
remain stored. Text replacement also checks complete name components, protected
words, negative examples, competing names and original transcript boundaries.
Uncertain matches keep the original text.

## Runtime availability

The pinned public TranscribeCpp v0.1.2 binary does not expose encoder snapshots.
The new path is capability-gated; the existing cepstral path remains available
with that binary. The reviewed native source patch and ABI contract are in
[ENCODER_FEATURES.md](../../Vendor/TranscribeCpp/ENCODER_FEATURES.md).
A local patched CPU build is experimental evidence, not a published SDK release
or verification of shipping accelerator and mobile paths. Do not change the
pinned download or claim deployment until those artifacts are separately built,
validated and distributed.

## Private real-audio replay

`GigaAMEncoderDictionaryLiveTests` is opt-in and uses an isolated private profile.
Configure the test host with:

- `PICHI_RUN_ENCODER_DICTIONARY_LIVE=1`
- `PICHI_ENCODER_DICTIONARY_PLAN`: local JSON manifest
- `PICHI_GIGAAM_MODEL_DIR`: an existing compatible model directory
- `PICHI_ENCODER_DICTIONARY_RESULTS`: a private output directory

The manifest contains `terms` mapping stable keys to canonical spellings and
`cases` containing `name`, `path` and `kind`. Audio paths point to finite,
16 kHz mono Float32 little-endian PCM, at most 15 seconds. Reference cases also
include a term `label` and `focal_start`/`focal_end` in seconds. Other cases are
replayed after all profiles are saved. A separate native capability check skips
unsupported SDKs; skipped or empty runs do not prove runtime support.

Keep audio, profiles, labels, model weights, generated manifests and results
outside Git. Score complete canonical-name occurrences with exact source-word
ranges, unchanged surrounding text and controls. Exclude an entire context once
any occurrence becomes a reference, and deduplicate repeated physical audio.
Freeze source annotations before examining correction results. Report tuning
and feedback retests separately from untouched validation.
