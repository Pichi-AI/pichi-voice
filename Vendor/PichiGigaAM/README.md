# Pichi GigaAM native runtime

This narrow Swift package runs Pichi's existing optimized GigaAM v3 ONNX exports on macOS. It uses Microsoft's pinned ONNX Runtime 1.24.2 package, whose macOS binary contains both arm64 and x86_64. No Python installation, cloud inference or separate STT server is needed.

The default execution provider is CPU. The CoreML diagnostic option was tested and failed for the current dynamic-shape attention graph. It is not enabled by the app; its package API is retained only for export-compatibility experiments. Apple Silicon CPU inference has been verified on a synthetic Russian sample. Rosetta checks are compatibility evidence, not native Intel performance measurements.

## Models and installation

`GigaAMModelCatalog` records SHA-256 checksums for the existing exports, in preference order:

| Export | Decoder | EOU threshold |
| --- | --- | --- |
| `v3_e2e_ctc_eou_v5.fp16.onnx` | BPE with punctuation, digits and Latin | 0.48 |
| `v3_ctc_eou_v3.fp16.onnx` | Russian characters | 0.44 |
| `v3_ctc_eou.fp16.onnx` | Russian characters | 0.5 |

The e2e export also needs `v3_e2e_ctc_vocab.txt` from the same model folder. The app's folder import copies and verifies these model files into its isolated Application Support namespace. It does not import other files from the source folder. `PICHI_GIGAAM_MODEL_DIR` can point development and tests to an existing local folder. The folder can contain the model directly or a subfolder named after its catalog ID.

Meeting jobs can pin `installedModelFingerprint()` (export ID, model checksum, vocabulary checksum and frontend revision). `PichiGigaAMProvider(expectedModelFingerprint:)` rejects an installed export that differs from the scheduled one. The fingerprint contains no local path.

The optimized weights include a private Pichi EOU head. Their download and distribution destination has not been published, so the app requires a verified local import and does not invent a public download URL. No weights, recordings or private training data are included in this package or Git.

## Inference contract

`GigaAMRuntime` serializes one model session. Input is finite 16 kHz mono float PCM. The frontend uses a 320-point periodic bf16-rounded Hann window, 160-sample hop and 64 HTK mel filters, matching the browser implementation. The same decoder serves final and live updates.

Word spans derive from CTC token emissions at 40 ms resolution. They are approximate emission spans, not forced alignment. Longer input uses 20-second ownership regions and one second of overlap on either side. Every word retains its absolute timing. EOU is calibrated using the model's operating threshold and temperature 2; it is returned only for an isolated utterance of up to eight seconds.

Cancellation is checked before loading, during hashing, between inference windows and after each native run. An in-flight native run finishes before teardown. `unload()` releases the model session. Reuse one runtime/provider for both meeting tracks to avoid loading two weight copies.

## Verification

Run portable decoder, frontend and corruption checks:

```bash
swift test --package-path Vendor/PichiGigaAM
```

Real-model checks are opt-in and read approved local fixtures without copying them into Git:

```bash
PICHI_GIGAAM_TEST_MODEL_DIR=/path/to/models \
PICHI_GIGAAM_TEST_WAV=/path/to/synthetic-russian-16khz.wav \
PICHI_GIGAAM_TEST_PARITY=/path/to/prototype/parity.json \
PICHI_GIGAAM_TEST_LONG=1 \
swift test --package-path Vendor/PichiGigaAM
```

The real-model fixture expects the existing synthetic Russian prototype sample, with `привет` in its first second and `русскую речь` in the complete transcript. The optional long check repeats that fixture with silence and verifies the overlap boundary. The optional reference parity JSON compares four stored frames from the original bf16 Torch frontend. Its log-mel differences are below 0.01, matching the pre-existing browser frontend; a separate deterministic PCM test checks the Accelerate DFT against the browser's arithmetic within 0.00002.

For explicitly authorized private recordings, set `PICHI_GIGAAM_PRIVATE_TEST_WAV` and run the `testAuthorizedLocalRecording` filter. Output contains timing and word counts only. `PICHI_GIGAAM_PRIVATE_REFERENCE_FILE` optionally supplies an existing local raw ASR transcript for normalized word disagreement metrics, which are not accuracy against human-checked truth. `PICHI_GIGAAM_TEST_CANCEL=1` also checks cancellation settling after a native inference window. Keep all inputs and reference files outside Git.
