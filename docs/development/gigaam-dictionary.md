# GigaAM acoustic dictionary

GigaAM dictionary references remain local audio examples, not updated model
weights. The provider binds every example to the model fingerprint and extractor
recipe. Existing correction capture, pronunciation storage and admitted profile
reads carry the original PCM and optional features from the same ASR pass.

The standard Mac Core ML package and compatible imported GGUF runtimes supply bounded 768-channel encoder features at a
40 ms clock. Matching calibrates its operating point from the active references
and other enrolled terms. A confirmed contextual correction complements two
other recordings through the existing `activeCaptures` selection; older examples
remain stored. Text replacement also checks complete name components, protected
words, negative examples, competing names and original transcript boundaries.
Uncertain matches keep the original text.

## Runtime availability

For GGUF compatibility, ordinary builds use the versioned local archive in
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
- Optional `PICHI_ENCODER_DICTIONARY_LEGACY_REFERENCE_DIR`: seed the isolated test profile with verified GGUF, unload it, then check that Core ML reads the saved references and prepares them from the original audio.

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

## macOS Core ML dictation

The default macOS GigaAM download is the pinned GigaAM v3 E2E CTC FP16 Core ML package (about 422 MiB). The same weights supply live previews, a full-context final transcript, token-derived word times and acoustic dictionary features. The app also recognizes the identical package previously installed under `DictationPreview` by version 0.3.1. Saved jobs with explicit older fingerprints retain their original selection; normal Mac dictation never requests their GGUF or ONNX downloads.

Core ML emits its final encoder representation before the CTC head for acoustic matching. Frame timing, window ownership, learning bounds, negative evidence and privacy admission follow the existing dictionary pipeline. The short preview uses a locally derived six-second shape; long-context repair and final recognition use the long graph. An accelerator failure can recover on CPU using the same model package. [Short shape generator](../../Vendor/PichiGigaAM/Tools/generate_preview_recipe.py).

Both fixed Core ML shapes mask padded encoder positions before attention softmax in every Conformer block. This prevents the size of the padded window from changing valid frames. To run the model-backed size invariance test, point `PICHI_GIGAAM_MASK_TEST_MODEL_DIR` at the pinned package directory.
