# Fast32 streaming profiling

Set `PICHI_MEETING_DETAILED_PROFILE=1` before creating the diarizer. The flag is
snapshotted per instance. The normal streaming path does not read clocks or build
JSON rows. No model, threshold, cache, cancellation or checkpoint behavior changes.

The existing `Nemotron3Diarizer.lastProfile` accumulates active host wall time from
`appendAudio`, `processBufferedAudio` and `finishStream`, using monotonic system
uptime. Gaps between these calls are excluded. `processComplete` keeps its existing
always-on profile and uses the same monotonic clock. Direct `step` calls contribute
model/state counters, but only the streaming entry points measure total active time.

| Field | Meaning |
| --- | --- |
| `appendSeconds` | Copy received PCM into the bounded frontend buffer |
| `melSeconds` | Pre-emphasis, STFT/mel extraction and frontend cache maintenance |
| `chunkSliceSeconds` | Chunk readiness, slicing, fixed-shape padding and mel cache eviction |
| `inferenceSeconds` | Inclusive model adapter call |
| `inputPrepSeconds` | Input construction inside inference |
| `projectionSeconds` | Split graph's host feature stacking/projection, inside input preparation |
| `packingSeconds` | Input packing, masks and feature provider, inside input preparation |
| `predictSeconds` | Core ML calls plus retry bookkeeping, inside inference |
| `firstPredictionSeconds` | First Core ML call, inside predict |
| `retryPredictionSeconds` | Retry after output backings are rejected, inside predict |
| `readbackSeconds` | Output lookup, strided array readback and Float conversion, inside inference |
| `stateUpdateSeconds` | Current output probability extraction plus FIFO/speaker cache update/compression |
| `outputAppendSeconds` | Tail probability trimming and returning each chunk's probabilities |
| `finishFlushSeconds` | Inclusive final flush, already included in total active time |
| `totalSeconds` | Measured streaming-call bodies, including per-chunk serialization and surrounding glue |

Add only the exclusive stages: append, mel, chunk slice, inference, state update
and output append. Do not add child timers to their parents or add finish flush
again. The remainder of total time includes control flow, autorelease cleanup and
profiling overhead. Prediction latency is host-observed and includes scheduled
CPU/GPU work; it does not establish GPU utilization or pure GPU execution time.
Final-summary serialization occurs after the measured call body and is excluded.

Diagnostic `AppLogger.info` rows contain `nemotron3DetailedProfile: 1`, an event,
outcome, final-flush flag, monotonic timestamp, absolute input/mel/output cursors
and the cumulative numeric profile. Per-chunk rows are capped at 2,000 per stream.
Suppressed rows are counted while all aggregate timers/counters continue. No event
array is retained. For a three-minute fast32 stream, expect about 71 chunk rows.
The final summary is emitted before the caller's deferred reset. Errors and
cancellation in a chunk emit a partial summary. Reset after an outside cancellation
emits `resetBeforeFinish` without guessing its cause. Summaries contain no error
descriptions, text, names, paths, audio, tensor contents or probability values.

`chunkCount` counts successful model/state steps. `failedChunkCount` counts thrown
inference/state steps. `flushChunkCount` is a subset of successful chunks.
`bufferedCallCount` includes the final flush call. `backingFallbackCount` counts
successful retrying calls only. If a prediction fails completely, its elapsed time
remains in `inferenceSeconds`, while incomplete model substage timings are absent.

Reset and restore clear profiling state. A restored stream reports its starting
sample/frame cursor separately, so new work is not presented as work from the
previous process. Diagnostic fields never enter the exact Float checkpoint.
The logger mirrors info rows to console in a DEBUG dependency build; a Release
build can collect them through unified logging or consume `lastProfile` in its
existing outer diagnostic adapter.

Model-free verification is available without downloads:

```bash
bash scripts/dev/test-fast32-runtime.sh /absolute/path/to/existing/FluidAudio
```

It checks the actual frontend values/cadence, exact checkpoint continuation through
cache compression, opt-in/default-off behavior, monotonic frontend timing, reset,
bounded row admission, numeric-only profile schema and model timing aggregation.
Native inference and physical performance still require a separate device run.
