# Opt-in Nemotron FP16 device diagnostic

`MobileNemotronFP16DiagnosticTests.testPinnedFP16DiagnosticReplay` compares local
FP16 monolithic v2 Nemotron presets without registering a product backend or
changing a preference. It exercises the existing `Nemotron3Models`, streaming
`Nemotron3Diarizer` and `MeetingFast32SpeakerIntervals`. The existing bounded
`CombinedResourceSamples` sampler is shared with the end-to-end meeting test.

This test is a model-local speed and output experiment. A passing run does not
establish production meeting latency, text attribution, privacy, background
execution or quality. Compare fast32 with fast32 W8A8 first. Fast128 also changes
chunk geometry, so it is a separate configuration comparison.

## Immutable inputs

Stage only these task-owned files under the existing test-asset root:

```text
audio/combined-ru.wav
diagnostics/NemotronFP16/learnable_sil_emb.bin
diagnostics/NemotronFP16/Nemotron3Diarizer_fast32.mlmodelc/
  model.mil
  coremldata.bin
  analytics/coremldata.bin
  weights/weight.bin
```

For fast128, use `Nemotron3Diarizer_fast128.mlmodelc` instead. No download or model
installation occurs in the test. Both candidates are pinned to public model
revision `25a90f97f254428d4b30374b76af9c74fdee8327`. Exact SHA256 and size checks cover
all four compiled-bundle files and the learned silence embedding before Core ML
opens the model. Unexpected files, symbolic links and mismatching runtime input or
output shapes fail. The candidate configuration and compute policy are captured
once, before the attempt.

The WAV must contain exactly 2,880,000 mono samples at 16 kHz, with a 5,760,044-byte
container. Supply its independently verified SHA256 through the environment,
rather than committing private fixture metadata. The test reads either its first
20 seconds or all 180 seconds in one-second blocks. It keeps no whole-waveform,
whole-mel or whole-probability buffer.

## Explicit gates

| Environment | Value |
| --- | --- |
| `PICHI_MOBILE_INFERENCE_ASSETS` | Existing test root or `application-support` |
| `PICHI_COMBINED_MEETING_E2E` | `1` |
| `PICHI_COMBINED_MEETING_PRIVATE_EVALUATION` | `1` |
| `PICHI_MEETING_DETAILED_PROFILE` | `1` |
| `PICHI_COMBINED_MEETING_TESTED_REVISION` | Exact lowercase 40-character tested commit |
| `PICHI_NEMOTRON_FP16_AUDIO_SHA256` | Independently frozen lowercase 64-character WAV digest |
| `PICHI_NEMOTRON_FP16_CANDIDATE` | `fast32` or `fast128`; required |
| `PICHI_NEMOTRON_FP16_COMPUTE_UNITS` | `cpuAndGPU` by default, or explicit `cpuOnly` |
| `PICHI_NEMOTRON_FP16_DURATION_SECONDS` | `180` by default, or explicit `20` |
| `PICHI_NEMOTRON_FP16_TRACE_READY_SECONDS` | `0` by default, or explicit `10` |

Without a candidate the test skips. A supplied candidate with missing or invalid
gates fails. It does not substitute another candidate or alter normal app compute
selection. Cancellation is forwarded to the owned detached inference task, which
joins its sampler and releases its model references before returning.

For a traced safety probe, select 20 seconds and a 10-second readiness delay.
After loading, the metadata log emits `candidate.trace_ready event=begin` and
waits 10 seconds before `candidate.inference event=begin`. The delay is separately
reported and excluded from model-load and inference timings. A requested
`cpuAndGPU` policy is not proof of GPU use. Confirm process-attributed device
execution with a separate trace, then measure the full 180 seconds without a
tracer or readiness delay.

Follow the repository's simulator, signing, frozen-copy and physical-device
verification rules before running. Do not replace an active user recording or
uninstall the app to stage a model. Test assets are retained after the run; record
their additional storage and preserve the original application files.

## Evidence and interpretation

The retained `NemotronFP16Diagnostic-<preset>-<compute>-<duration>s.json` XCTest
attachment contains exact pins, the complete config, source coverage, cumulative
per-chunk profiles, final profile, anonymous speaker-slot intervals and bounded
process-footprint samples. It contains no transcript, audio, embeddings, voice
names or probabilities. The attachment is independent of interleaved stdout.

All expected chunks must complete with no failed or skipped chunks. The exact
final output geometry follows the existing centered mel frontend:

```text
frames = 1 + floor((samples + nFFT - window) / hop)
nFFT = 512, window = 400, hop = 160
20 seconds: 2,001 frames; 180 seconds: 18,001 frames
fast32: 8 or 71 chunks; fast128: 2 or 18 chunks
```

Speaker intervals clip to the physical 20/180-second source prefix. The final
extra mel frame does not extend the recording.

Validation/hashing time is reported separately and excluded from the sampled
run, which starts immediately before model loading. Hashing can warm filesystem
caches; this is not a claim of a cold filesystem or cold Core ML cache. Run wall
includes model load, adapter initialization, any readiness delay, source reads,
inference, interval construction and host-scoped release. The final metadata JSON
allocation occurs after the sampler has stopped and is outside that scope.

Inference wall includes source reads and interval construction. Cumulative
`profile.totalSeconds` measures active diarizer calls. The profile's nested stages
must not be added together: inference contains input preparation, prediction and
readback; prediction contains first attempt plus fallback retry. Final flush is an
inclusive subset. Derive per-chunk times by subtracting successive cumulative
profiles. CPU counters cover all app threads, not the GPU or a single model call.
Footprint is sampled at 250 ms, not a system-wide or GPU allocation peak.
Host-scoped release does not prove that the driver purged its caches.

A failed model load or inference produces `success=false`, a bounded stage name
and numeric error code. The test fails rather than crediting partial output as a
speed result. Process termination can prevent XCTest attachment export; preserve
that failed attempt and its trace separately.
