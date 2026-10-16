# Long meeting memory and scheduling, October 15, 2026

## Observed physical-device failure

The latest original interrupted iPad meeting lasted 62 minutes 23 seconds. It used
GigaAM, memory-only audio, speaker labels enabled and PII protection disabled.
Read-only device evidence remains in ignored local storage; this report contains
no private transcript, recording identifier or device identifier.

The recorded terminal error was `errorKind=overload`: 383,862 pending frames
against a 384,000-frame ceiling, or 23.99 seconds at 16 kHz. Capture reported writer
backpressure. No fresh system OOM/Jetsam report was found for this attempt. This
establishes a processing backlog failure, not a demonstrated memory leak.

The old live window alternated ASR, diarization and voice matching. One final
12-second window spent about 1.38 seconds preparing ASR, 3.32 seconds recognizing,
0.21 seconds loading Nemotron, 4.37 seconds diarizing and 2.75 seconds matching
voices. Earlier model loading and growing transcript checkpoints added stalls.
Small bounded recognition windows alone did not make the combined workload fast
enough to keep the capture queue below its limit.

## Processing and ownership

**No setting enables live diarization.** Speaker analysis waits until Stop, then
uses one continuous Sortformer state for the complete recording of each track.
Bounded replay slices feed that same state and finalize it once; slices are not
independent meetings and do not reset speaker slots. Optional owner identification
uses WeSpeaker in a separate phase after the diarizer releases its weights.

During memory-only capture, bounded windows run ASR and optional PII protection.
The existing provider/backend registry, prepared ASR scope, residency gate, privacy
context and canonical store remain the integration boundaries. Heavy audio models
operate in joined phases rather than remaining resident together. The smaller
privacy model follows its existing service ownership and protected publication
contract; live and replayed text must pass it before publication when enabled.

If optional live recognition fails or falls behind, capture continues into the
complete RAM recording. After Stop, ASR replays that sealed recording in bounded
20-second windows with the original model/artifact selection and a fresh privacy
context, followed by global diarization. An archive/codec failure or exhausted
archive budget remains a capture error; deferred ASR cannot repair missing audio.

The request freezes backend, model and artifact identity for the attempt. One
explicit `analysisTask` owns post-stop work. Cancellation joins it before archive
cleanup and lease retirement. Success, failure and cancellation clear owned audio.
Native operations use autorelease pools, and timing/footprint diagnostics contain
scalar metadata rather than transcript contents.

## Audio retention and memory bounds

| Audio setting | During capture | After Stop |
| --- | --- | --- |
| Saving disabled | Complete mono recording encoded into RAM only | Bounded decode/replay for deferred ASR if needed and global diarization; clear RAM afterward |
| Saving enabled | Existing retained recording files | Continuous bounded resampling into a private scoped PCM derivative; replay without loading the whole recording into RAM |

The memory-only archive uses native AAC at 48 kbps, or 32 kbps when the encoder
supports that rate instead. It seals at most 30 seconds per segment and keeps a
bounded PCM tail and decoded-segment cache. The encoded archive has a 256 MiB
ceiling. Eight hours at the tested rate retained about 174 MiB including packet
metadata. Encoded recording memory grows with duration; it is intentional retained
data, not constant memory or an unbounded PCM queue.

The live PCM transport ceiling is 60 seconds, or 3,840,000 Float32 bytes at 16 kHz,
including queued and in-flight recognition. Recognition releases consumed PCM and
queue credit before serialized text checkpoint IO. Adaptive preview scheduling
omits optional repeated prefixes when model work is expensive. Canonical JSON is
compact and an unchanged history index is not replaced on every checkpoint.
Transcript text, speaker timelines and checkpoint work still grow with duration.

With audio saving enabled, resampling keeps one converter across each continuous
format/capture-era run and reads at most 32K native frames at a time. The PCM
derivative is opened with private permissions and unlinked before the first audio
write. Its descriptor owns storage until cleanup, including process termination.
At 16 kHz mono Float32 this still requires about 1.84 GB of disk space for eight
hours. This derivative is exclusive to the retained-audio path. Saving disabled
has no audio-file fallback, including when ASR is deferred or memory is exhausted.

## Verification evidence

Source baseline for this report: `446d33ef` on
`codex/tablet-long-session-memory-20261015`. Results below distinguish isolated,
integrated and physical-device evidence; they are not interchangeable.

| Check | Result and scope |
| --- | --- |
| Native AAC accelerated archive stress | Two synthetic eight-hour runs: each accepted 460,800,000 frames, produced 960 segments and retained 182,160,960 bytes; measured process footprint peaked near 213 MB on the first run and 120 MB on the second, returning to about 23 MB after clear |
| Backend and materializer regression | 62/62 passed at `1aa59c71`; covers bounded replay and backend contracts, not eight-hour physical recording |
| Independent integrated review | Four material P2 findings were corrected; follow-up review cleared `cc0c8e37`, before the later visible-test accessibility changes |
| Product compilation | iOS Release and macOS builds passed earlier in this task; checks against the final combined source are still pending |
| Physical native archive codec round trip | Passed on the iPad; does not validate complete recording, ASR or speaker quality |
| Hosted post-stop minute scenario | Failed with `SessionDeactivationFailed`; `cc0c8e37` changes stop/reset, producer drain and session-deactivation ordering; a visible passing rerun remains required |
| Actual app UI attempt | Start visibly entered recording and the timer reached 1:59, but the UI test could not address Stop because of iPadOS 17 identifier propagation; `446d33ef` corrects that accessibility issue |

Earlier hosted UI runs that only launched the app or played speech while idle are
not successful recording tests. The failed actual-app run did not complete Stop,
post-processing and saved-result verification. A later test restart lost its
RAM-only audio; partial saved text does not establish a completed meeting. The
user subsequently confirmed pressing Stop for the requested test recording.

### Pending visible final verification

**PENDING: final integrated and visible-device results have not been recorded.**
The repeat must inspect and save native screenshots after actual Start, advancing
recording state, Stop, processing and the saved result, using the exact frozen,
signed build. Speech playback must begin only after recording is visibly active.
The repeat must confirm captured speech, post-stop global diarization, completion
without a capture/session error, and no audio files when saving is disabled.
The current rerun has no completed result in this report.

## Limits and remaining evidence

The synthetic archive stress does not prove an eight-hour iPad microphone session,
thermal stability, background operation, full-model memory behavior or speaker/PII
quality. Global diarization behavior needs actual speaker-quality evaluation.
Bounded PCM and serialized model residency reduce pressure; the encoded archive,
transcript, model allocations and operating-system overhead still consume memory.
The 256 MiB cap is explicit, so this is not an unlimited-duration or every-device
guarantee. Device-specific admission and long physical sessions remain necessary
before claiming reliable eight-hour operation.

## Implementation references

- [MeetingProcessingPipelineMemoryAttempt.swift:244](../../Sources/Fluid/Services/Meeting/MeetingProcessingPipelineMemoryAttempt.swift#L244): joined cancellation, post-stop analysis and deferred ASR replay.
- [MeetingMemoryAudioArchive.swift:71](../../Sources/Fluid/Services/Meeting/Platform/MeetingMemoryAudioArchive.swift#L71): RAM archive budget and AAC bitrate admission.
- [MeetingProductionParakeetNemotronRuntime.swift:194](../../Sources/Fluid/Services/Meeting/Backend/MeetingProductionParakeetNemotronRuntime.swift#L194): continuous stopped-recording diarization state.
- [MeetingEpochAudioReplay.swift:89](../../Sources/Fluid/Services/Meeting/Backend/MeetingEpochAudioReplay.swift#L89): retained-audio derivative ownership and bounded conversion.
- [IOSMeetingCaptureEngine.swift:400](../../Sources/Fluid/Services/Meeting/Platform/IOSMeetingCaptureEngine.swift#L400): capture stop and producer-drain ordering.
