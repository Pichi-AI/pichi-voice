# Pichi GigaAM native runtime

This package runs the ready-made [Inhum GigaAM v3 Core ML conversion](https://huggingface.co/inhum/gigaam-v3-coreml), pinned to revision `43dc96918bc232deafa7b7d0600fb499806f7ac1`, and retains existing ONNX imports. No graph rewriting, model conversion, Python installation or server is needed by the application.

Native Core ML prefers GPU using `cpuAndGPU` on every supported device. CPU is the reserve path when GPU preparation or execution fails; its concrete reason is shown in the existing settings. Both paths use the same unchanged package. Cancellation, invalid audio and failed source verification remain errors. Configured execution is distinct from measured hardware utilization. Pinned ONNX jobs keep their exact content identity and CPU compatibility.

## Models and installation

The default download is the published Core ML package plus its required window, filterbank and vocabulary, totaling 442,427,628 bytes. All six files are pinned by SHA-256. Existing files do not change the selected source; folder imports become selected after explicit import and verification:

| Export | Decoder | EOU threshold |
| --- | --- | --- |
| `gigaam_v3_e2e.mlpackage` | BPE with punctuation, digits and Latin | No EOU head |
| `v3_e2e_ctc_eou_v5.fp16.onnx` | BPE with punctuation, digits and Latin | 0.48 |
| `v3_ctc_eou_v3.fp16.onnx` | Russian characters | 0.44 |
| `v3_ctc_eou.fp16.onnx` | Russian characters | 0.5 |
| `v3_e2e_ctc.int8.onnx` | BPE with punctuation, digits and Latin | No EOU head |

The e2e export also needs `v3_e2e_ctc_vocab.txt` from the same model folder. The app's folder import copies and verifies these model files into its isolated Application Support namespace. It does not import other files from the source folder. `PICHI_GIGAAM_MODEL_DIR` can point development and tests to an existing local folder. The folder can contain the model directly or a subfolder named after its catalog ID.

Meeting jobs can pin `installedModelFingerprint()` (export ID, model checksum, vocabulary checksum and frontend revision). `PichiGigaAMProvider(expectedModelFingerprint:)` rejects an installed export that differs from the scheduled one. The fingerprint contains no local path.

The earlier [community ONNX export](https://huggingface.co/istupakov/gigaam-v3-onnx) remains pinned to revision `322c3b29492673eb7d0b434bfa9dfb8653e34d02` for compatibility. Both public conversions derive from the official GigaAM model and declare MIT; attribution is preserved in Notices. The existing progressive downloader verifies sizes and hashes before publishing a complete folder atomically. Settings and onboarding share this operation for both formats.

Pichi's optimized EOU weights retain their verified local import path; their distribution destination is still unpublished. No weights, recordings or private training data are included in this package or Git.

### Default download and optional folder import

In Speech Recognition, choose GigaAM and click Download, then Activate. The application fetches and verifies the published Core ML package and its three preprocessing/decoding files. No external application or manually supplied file is required.

For a local model, use GigaAM's Other options menu, then Import model folder. Choose a folder containing one supported export. For the same public model downloaded manually, the folder is:

```text
gigaam-local/
  gigaam_v3_e2e.mlpackage/
    Manifest.json
    Data/com.apple.CoreML/model.mlmodel
    Data/com.apple.CoreML/weights/weight.bin
  gigaam-window.f32
  gigaam-melfb.f32
  gigaam-vocab.txt
```

For our existing custom E2E v5 model, the folder is:

```text
gigaam-custom/
  v3_e2e_ctc_eou_v5.fp16.onnx
  v3_e2e_ctc_vocab.txt
```

The earlier public INT8 import requires `v3_e2e_ctc.int8.onnx` and `v3_e2e_ctc_vocab.txt`. Older character exports require only their named ONNX file. Imports accept the registered filenames and exact SHA-256 checksums in `GigaAMModelCatalog`; another export is not automatically compatible. The shared operation copies only required files and selects the import after complete verified publication. Click Activate to load it.

The published Core ML binary contract is checked independently of its model card: the filterbank bytes are bin-major, logits are FP16 with padded strides, and the reported encoded length can round upward above 2048 input frames. The adapter reads the supplied files unchanged and caps CTC output by both real audio length and physical tensor dimensions. No graph or weight changes are made.

To return to the public model, choose Other options, then Use Hugging Face model (default), and click Download or Activate. This switches the source without deleting the imported files. A failed import or cancellation before publication keeps the previous source. Recording and meeting operations block source changes until their owned work finishes. Already scheduled meeting attempts retain their pinned artifact identity.

The developer `PICHI_GIGAAM_MODEL_DIR` override and descriptor-named artifact directories remain explicit local references for tests and pinned jobs. They are separate from the first-run default and are not required for normal installation.

## Library characteristics

The default published Core ML files occupy 421.9 MiB. The imported E2E v5 ONNX export and vocabulary occupy 435.2 MiB; older character exports occupy about 428.8 MiB. The existing 4 GB system-RAM recommendation is not a model RAM measurement. The Core ML route prefers GPU on Apple Silicon and Intel; actual compatibility and measured performance remain device-specific.

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
