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

Ordinary builds use the versioned local archive in
`Vendor/TranscribeCpp/Artifacts`. Its manifest records the checksum, pinned
upstream source, reviewed patch, licenses and platform provenance.
`scripts/dev/check-transcribe-sdk.py` verifies that archive during portable
checks. SwiftPM extracts it without extra credentials or runtime environment
overrides.

The enhanced macOS arm64 slice supplies encoder snapshots with both CPU and
Metal. The original Intel and iOS implementations remain in the archive; the
optional API is unavailable there and the existing fallback remains supported.
This does not enable voice enrollment on mobile. The native ABI and reproducible
package build are documented in
[ENCODER_FEATURES.md](../../Vendor/TranscribeCpp/ENCODER_FEATURES.md).

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

## macOS dictation previews

On supported Apple Silicon Macs the default public GigaAM GGUF retains ownership of the final transcript, timestamps and dictionary evidence. A pinned FP16 Core ML companion can handle live previews on the CPU and Neural Engine. An admitted recording freezes its preview route. Local imports, meetings, file transcription and unsupported devices keep their existing route.

The companion is prepared asynchronously. An existing installation with only GGUF can start dictating immediately. The first eligible admission starts the optional download (about 422 MiB); a later recording can use it once preparation finishes. The companion has its own subdirectory under the default GigaAM store and is removed with the default model. Ordinary dictation continues if optional preparation or prediction fails.

The incremental provider consumes new 16 kHz samples on the existing capture clock. It aligns the short window's observations using word identity and audio time, checks independent observations before sealing a core, uses more context on disputed boundaries, and reconciles phrase ends against the native model. Capture, privacy admission and the final dictionary pass use their existing services. Both graphs derive from the same verified public package. The six-second shape recipe ships without model weights. Its development generator is [generate_preview_recipe.py](../../Vendor/PichiGigaAM/Tools/generate_preview_recipe.py).
