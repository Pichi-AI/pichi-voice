# Nemotron fast32 W8A8 integration

The existing model store installs the split W8A8 model and its two host assets as one immutable `fast32-w8a8.nemotronbundle`, under cache version `v2-fast32-w8a8`. This keeps the old package cache separate and preserves explicit legacy package imports. No model weights are stored in Git.

- Model repository: [FluidInference/nemotron-3-diarization-coreml](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/tree/25a90f97f254428d4b30374b76af9c74fdee8327), revision `25a90f97f254428d4b30374b76af9c74fdee8327`.
- Variant: `split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc`.
- Weight SHA-256: `99e2ae43ac6a513abf99951b35a75fb6bc51d2287c3c1af48a9657d917e57aed`.
- Host assets: `learnable_sil_emb.bin`, `pre_encode_proj_t.bin`.
- All six regular files have exact pinned SHA-256 values in `MeetingModelInstaller`.
- Host/runtime source: [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio/tree/82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8/Sources/FluidAudio/Diarizer/Nemotron3), revision `82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8`, Apache-2.0. The bundled notice includes the license. The model card declares OpenMDW-1.1 for the weights.

## Extension boundary

Four inference/state files are adapted locally because the app's current FluidAudio revision lacks the split graph host projection, 10ms output and streaming tail frontend. This avoids upgrading unrelated ASR, VAD and embedding behavior. Existing public FluidAudio mel extraction, aligned tensor helpers and logging are reused. Model-independent meeting orchestration continues to use the same factory/session contracts and phased model residency.

Adaptations from the pinned runtime: remove network/cache loading in favor of the existing model store; mark types nonisolated for app targets; use existing public helper imports; configure the author's fixed 160-sample hop, 400-sample analysis window and 0.97 pre-emphasis where the older mel class keeps these fields private; check cancellation between native prediction chunks. The original tensor projection, speaker state updater, streaming frontend and output stride handling are retained.

The split configuration has 32 core frames, 4 right-context frames, 40 FIFO frames and 264 cache frames. One phase loads shared model weights, while each track has fresh streaming state. Replay feeds at most one second of PCM at a time. Only compact speaker intervals accumulate; raw probabilities are reduced after every chunk. Finalization flushes and clips the tail to the physical duration. Shorter than 200ms activity is discarded, matching the evaluation configuration.

The author-compiled bundle bypasses compilation without becoming an owned temporary derivative. Cleanup never deletes installed compiled source assets. Legacy package compilation retains the joined cancellation owner. A changed source snapshot is refused before reuse.

## Hardware limits

The pinned `model.mil` declares `main<ios17>`. Runtime loading uses CoreML `.all`, allowing its CPU/GPU placement on machines without an ANE. It never substitutes the legacy model after a load or inference failure. The A10X iPad Pro has no ANE; successful compilation on Apple Silicon or the model card's ANE measurements do not establish A10X compatibility, memory, speed or energy use. Run the exact frozen signed app on the physical iPad before claiming support.

## Verification

- `bash scripts/dev/test-nemotron-compile-owner.sh`: ownership, reuse, source drift, concurrent preparation, cancellation, author-compiled pass-through and cleanup, using synthetic files only.
- `bash scripts/dev/test-fast32-runtime.sh /absolute/path/to/existing/FluidAudio-checkout`: compiles only the pinned public helper source and adapted inference sources in this worktree. It downloads nothing and loads no neural model. Tests configuration geometry, interval continuity across chunks, overlap, final tail clipping, malformed output rejection, short fragments, cancellation and model-free streaming/batch mel parity.

Full app builds, independent integrated review, physical-device combined memory/quality tests and measured Russian meeting quality are separate parent-task checks.
