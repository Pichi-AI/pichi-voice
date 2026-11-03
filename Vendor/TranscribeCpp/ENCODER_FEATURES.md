# Optional encoder feature snapshots

The original upstream v0.1.2 binary does not export the feature API.
A compatible locally packaged SDK can expose it on macOS arm64 while retaining
the original Intel and iOS slices. `Session.supportsEncoderFeatureSnapshots` is false
when any required symbol is missing, the ABI version differs, or the loaded
model does not implement the capability. Dependency selection is owned by `Package.swift`; the build script below
produces an artifact without changing that selection or publishing a release.
`Session.nativeEncoderFeatureAPIAvailable` reports only ABI availability before
model preparation. It never loads weights. Instance capability validation is
still required after preparing the frozen model selection.

`runWithEncoderFeatures` holds the existing model compute lock across the ASR
call, metadata query and feature copy. It returns an owned transcript and owned
time-major Float32 sequence from that same successful run. It does not load a
second model, perform another encoder pass, use environment variables, or write
features to disk. Async calls use the existing joined cancellation bridge.

`runWithOptionalEncoderFeatures` shares that locked single-pass operation. On
legacy SDKs or unsupported models it returns the ASR transcript with nil
features. If ASR succeeds but metadata or feature copying fails, it clears the
capture and keeps that same transcript. It never retries the encoder. ASR
failure, cancellation and invalid caller byte limits still throw. The strict
`runWithEncoderFeatures` operation continues to throw on capture failure.

Snapshots have at most 600 frames, 1024 channels and 2 MiB of feature bytes.
Callers may request a smaller byte limit. Invalid clocks, zero generation,
changed metadata/generation and nonfinite features fail closed. Native run or
copy failure and cancellation clear the capture. Already returned value types
remain caller-owned after another run or session teardown.

The sequence is the final encoder representation before the decoding head,
not a speaker embedding. A caller must additionally bind it to the immutable
model/artifact fingerprint of the attempt. The native generation identifies a
run within one session, not an identity shared between sessions.

## Native ABI v1

The optional symbols are resolved only from the loaded image that owns
`transcribe_run`. No direct link to a new symbol is required by legacy clients.

```c
uint32_t transcribe_encoder_features_api_version(void); /* exactly 1 */
int32_t transcribe_encoder_features_supported(const struct transcribe_model *model);
int32_t transcribe_clear_encoder_features(struct transcribe_session *session);
int32_t transcribe_get_encoder_features(
    const struct transcribe_session *session,
    uint32_t *frame_count, uint32_t *dimension,
    uint32_t *sample_rate, uint32_t *hop_samples, uint64_t *generation,
    float *destination, uint64_t capacity_elements);
```

Status returns use existing `transcribe_status` numeric values. Unsupported
models fail with `NOT_IMPLEMENTED`. A null destination with zero capacity is a
metadata query. A subsequent caller-buffer copy must report identical metadata
and generation. Insufficient capacity and malformed metadata must never write
past the caller buffer. The clear operation is required before an attempt that
can fail generic validation without dereferencing its session. This preserves
the SDK's existing invalid-pointer/null-PCM validation contract. Swift clears
under the compute lock before ordinary, snapshot, Whisper and batch runs.

For GigaAM v3 E2E CTC, native recipe version 1 copies the existing session
`enc_host` buffer after successful decoding: 768 channels, 16000 Hz clock,
640-sample hop (40 ms). This model-specific implementation stays inside the
native family adapter; common application orchestration consumes the generic
capability and metadata.

## Prototype build and validation

The native patch is based on upstream `handy-computer/transcribe.cpp` v0.1.2,
commit `33d5c383e43e6acbd572845866ea75b8c7959fa5`. It is a reviewed source patch, not an upstream release. Preserve the upstream
license and notices when rebuilding. The delivery package below builds the Mac
arm64 CPU and Metal implementation and preserves legacy platform code.

Run focused Swift tests with isolated outputs:

```sh
swift test --package-path Vendor/TranscribeCpp \
  --scratch-path .build/native-feature-swift --jobs 4 \
  --filter EncoderFeatureSnapshotTests
```

The tests use injected API closures to verify bounds, copy ownership,
cancellation, generation changes, native errors, nonfinite rejection and
missing symbols without loading any model. A patched-native actual-audio test
is still required to establish runtime support and numerical parity. It must
use a task-owned process and the same frozen model weights, then verify that
ASR text is unchanged, repeated runs advance generation, failed/canceled runs
cannot expose previous audio, and both CPU and shipping accelerator paths
retain their normal ownership and cancellation behavior.


## Self-contained local SDK package

`Vendor/TranscribeCpp/scripts/build-encoder-sdk.py` implements the upstream
Apple CI linkage contract: static transcribe and ggml archives are force-loaded
into one dynamic framework, with embedded Metal shaders. No external ggml dylib,
second model, debug dump or `DYLD_LIBRARY_PATH` is needed. It pins the source
commit and verifies the exact patch through a separate temporary Git index.
The official v0.1.2 input ZIP must match SHA256
`4092276cd295860ae9637a2913cf2d8747f39d454bb7fb3c79d6af9f858a4bb8`.

```sh
python3 Vendor/TranscribeCpp/scripts/build-encoder-sdk.py \
  --work-dir "$PWD/.build/encoder-sdk" \
  --output /absolute/private-artifacts/encoder-sdk \
  --official-archive /absolute/cache/TranscribeCpp-v0.1.2.xcframework.zip \
  --jobs 4
```

The output directory must not exist. Add `--cmake /absolute/path/to/cmake`
when CMake is not on PATH. Xcode, its Metal toolchain and an Apple Silicon Mac
are required. The script builds and runs the two model-free native ABI tests,
validates the packaged framework with a dynamic-link smoke, verifies its
exports/system-only dependencies and prints the SwiftPM archive checksum.
Inputs and toolchain are recorded for repeatable builds; timestamps and signing
mean separate builds are not promised to have identical archive bytes.

Only macOS arm64 is rebuilt. The universal Mac framework retains the official
Intel slice's code, verified after stripping signatures on disposable thin
copies because signing the universal framework updates its signatures. Both
original iOS slices and XCFramework platform metadata remain byte-identical.
The optional snapshot API stays unavailable on those legacy architectures;
callers must continue using the capability check. The archive includes original
transcribe, ggml and miniz licenses plus a platform-specific notice.

The synthetic probe may additionally validate a caller-selected existing model:

```sh
/absolute/private-artifacts/encoder-sdk/encoder-sdk-smoke model.gguf cpu
/absolute/private-artifacts/encoder-sdk/encoder-sdk-smoke model.gguf metal
```

It uses one second of generated audio, four CPU threads and no audio device.
It checks 25 by 768 finite, nonzero feature values, the clock, copy ownership, advancing
generations and invalid-attempt clearing, then frees the session and model.
CPU and Metal probes are separate owned processes. These are SDK integration
checks, not speech-quality or microphone tests.
