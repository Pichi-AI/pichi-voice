# Pichi GigaAM native runtime

This narrow Swift package runs local GigaAM v3 ONNX exports on macOS, including the compact public INT8 export and Pichi's existing optimized exports. It uses Microsoft's pinned ONNX Runtime 1.24.2 package, whose macOS binary contains both arm64 and x86_64. No Python installation, cloud inference or separate STT server is needed.

The default execution provider is CPU. The CoreML diagnostic option was tested and failed for the current dynamic-shape attention graph. It is not enabled by the app; its package API is retained only for export-compatibility experiments. Apple Silicon CPU inference has been verified on a synthetic Russian sample. Rosetta checks are compatibility evidence, not native Intel performance measurements.

## Models and installation

`GigaAMModelCatalog` records SHA-256 checksums for existing imports and the pinned public download. Existing complete imports retain their preference:

| Export | Decoder | EOU threshold |
| --- | --- | --- |
| `v3_e2e_ctc_eou_v5.fp16.onnx` | BPE with punctuation, digits and Latin | 0.48 |
| `v3_ctc_eou_v3.fp16.onnx` | Russian characters | 0.44 |
| `v3_ctc_eou.fp16.onnx` | Russian characters | 0.5 |
| `v3_e2e_ctc.int8.onnx` | BPE with punctuation, digits and Latin | No EOU head |

The e2e export also needs `v3_e2e_ctc_vocab.txt` from the same model folder. The app's folder import copies and verifies these model files into its isolated Application Support namespace. It does not import other files from the source folder. `PICHI_GIGAAM_MODEL_DIR` can point development and tests to an existing local folder. The folder can contain the model directly or a subfolder named after its catalog ID.

Meeting jobs can pin `installedModelFingerprint()` (export ID, model checksum, vocabulary checksum and frontend revision). `PichiGigaAMProvider(expectedModelFingerprint:)` rejects an installed export that differs from the scheduled one. The fingerprint contains no local path.

The default download is the community ONNX export from [istupakov/gigaam-v3-onnx](https://huggingface.co/istupakov/gigaam-v3-onnx), pinned to revision `322c3b29492673eb7d0b434bfa9dfb8653e34d02`. Its model has 224,893,347 bytes and SHA-256 `2e3fcb7a7b66030336fd10c2fcfb033bd1dc7e1bf238fe5cfd83b1d0cfc9d28e`; its 2,007-byte vocabulary uses the same hash as existing e2e imports. It derives from the official GigaAM v3 model and uses its MIT license, preserved in the app's Notices. It has no Pichi EOU head. The existing provider prepares missing files through the shared progressive downloader, validates size and checksums, atomically publishes a complete directory and then loads the native session. Onboarding and Settings share this preparation operation.

Pichi's optimized EOU weights retain their verified local import path; their distribution destination is still unpublished. No weights, recordings or private training data are included in this package or Git.

## Library characteristics

The preferred E2E v5 export and its vocabulary occupy 456,341,702 bytes (435.2 MiB) on disk. The older character exports occupy about 428.8 MiB. The library separately shows the existing 4 GB system-RAM recommendation; this is not a measurement of model RAM consumption. Both Apple Silicon and Intel use CPU inference.

E2E output includes punctuation, capitalization and text normalization. The FP16 conversion reduces weight storage, and Pichi's trained EOU head detects phrase completion using the shared speech encoder. The native provider does not include the browser/server domain-term spotter or a separate grammar-correction model. Older character exports do not produce the E2E formatting features. The installation snapshot supplies the imported descriptor's characteristics to the common library card without filesystem reads during rendering.

The library uses the same shared percentage rows and liquid bars as the other models: speed 90% and accuracy 90% for Russian. These are relative product ratings chosen for the library scale, not measured percentages of correctly recognized words and not a conversion from WER. The existing tooltip keeps their reference context:

- On October 12, 2026, the synthetic Russian prototype fixture (8.4765 seconds, 16 kHz mono) took 0.9674 seconds to transcribe with the preferred v5 export on an Apple M4 Max CPU, about 8.8 times real time. The model load took 0.8108 seconds and is excluded. This short warm inference measurement does not establish Intel, long-recording or concurrent-load performance.
- The [publisher's evaluation](https://github.com/salute-developers/GigaAM/blob/main/evaluation.md) reports average normalized word error rate (WER) across ten Russian datasets: 12.0% for base v3 E2E CTC and 9.1% for base v3 CTC. Lower WER is better. These are reference values for the base models, not measurements of our optimized artifacts or the library's relative accuracy score.

No ASR accuracy percentage is inferred from the EOU head's phrase-completion classification metrics.

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
