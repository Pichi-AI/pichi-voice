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

Source baseline for this report: `d379b83d` on
`codex/tablet-long-session-memory-20261015`. Results below distinguish isolated,
integrated and physical-device evidence; they are not interchangeable.

| Check | Result and scope |
| --- | --- |
| Native AAC accelerated archive stress | Two synthetic eight-hour runs: each accepted 460,800,000 frames, produced 960 segments and retained 182,160,960 bytes; measured process footprint peaked near 213 MB on the first run and 120 MB on the second, returning to about 23 MB after clear |
| Backend and materializer regression | 62/62 passed at `1aa59c71`; covers bounded replay and backend contracts, not eight-hour physical recording |
| Independent integrated review | Four material P2 findings were corrected; follow-up reviews cleared the integrated source through `d379b83d`, including lifecycle, cancellation, bounded DEBUG input and existing extension points |
| Product compilation | Exact iOS optimized Debug and Release `d379b83d` built; frozen Release passed strict signature verification and was installed after recovery; earlier macOS product build passed, but final combined macOS product build was not rerun |
| Portable repository checks | Passed after correcting a test cleanup race for a disappearing Darwin process group; application code was unchanged by that test fix |
| Physical native archive codec round trip | Passed on the iPad; does not validate complete recording, ASR or speaker quality |
| Hosted post-stop minute scenario | Failed with `SessionDeactivationFailed`; after the stop/reset and session-order fix, the ordinary Release app completed the visible physical rerun below |
| Actual app UI failure and fix | An earlier Start visibly entered recording, but the UI test could not address Stop because of iPadOS 17 identifier propagation; `446d33ef` corrects that accessibility issue |
| Visible ordinary Release app rerun | Passed on the physical iPad: 3:45 meeting, 67 saved transcript segments, three speaker labels, completed processing, no failures and zero reported dropped samples |
| Quiet full-meeting physical run | Optimized Debug `d379b83d`, actual Start/Stop UI, complete 59:05.421 input accepted and replayed; completed with 8,863 final segments, five speaker labels, no failures and zero dropped samples; the data-loss incident below limits the overall result |
| Recovery verification | All 30 previous session manifests plus the new completed test were restored and verified by SHA-256 after device round trip; all 38 model files and the original preferences were restored; final Release history navigation passed 1/1 |

Earlier hosted UI runs that only launched the app or played speech while idle are
not successful recording tests. The failed actual-app run did not complete Stop,
post-processing and saved-result verification. A later test restart lost its
RAM-only audio; partial saved text does not establish a completed meeting. The
user subsequently confirmed pressing Stop for the requested test recording.

### Visible physical verification

The tested app is the frozen, development-signed ordinary Release product from
`446d33ef`, without a hosted test service or injected app launch environment. Its
executable SHA-256 is
`2075eb8999dd7b197dea09ac423ee291f1d596f5947cffc122fd32c7c174be78`.
The parent inspected the real iPad through QuickTime and saved native screenshots
at the actual Start, advancing recording, Stop, speaker-processing and completed
transcript checkpoints. The UI runner waited for an explicit parent ACK at each
checkpoint before proceeding.

In the first completed rerun, native diagnostics show ASR during recording and
the first Nemotron phase only after Stop. Global processing completed in about
38 seconds. Phase-sampled process footprint peaked near 296 MiB; those samples
are not a continuous peak-memory measurement or a leak test. The saved manifest
has `memoryOnly`, `transcriptIsComplete=true`, no failures, no audio chunks and
zero reported dropped samples. Its session directory contains only `session.json`
and an empty `tracks` directory. The existing model, save-audio, speaker-label and
PII settings match the values read before testing.

This rerun captured ambient speech. Runner playback did not establish recognition
of the intended synthetic fixture, so it is not evidence of fixture accuracy or
speaker quality. The subsequent loudspeaker scenario did not pass its fixture
assertion and was stopped at the user's request. It is not counted as a pass.

### Quiet full-meeting physical verification

The user requested direct audio input without a loudspeaker. A DEBUG-only capture
adapter incrementally decoded an existing local Fathom audio track into the actual
capture owner and PCM sinks. It did not create a player or activate microphone
capture. Release compilation excludes the adapter's entry point. The normal
recording UI, RAM archive, processing pipeline and persistence remained in use.

The complete input lasted 3,545.421 seconds and was fed at 1.8x speed in about
32:49.680 wall time. Native recording screenshots were saved every 30 seconds;
the parent inspected actual recording, processing and completion checkpoints.
Both the producer and stopped-recording ASR accepted exactly 56,726,736 frames at
16 kHz. The 178 replay windows cover the entire source, and the final transcript
ends at 3,545.421 seconds. Accelerated input reached the live queue limit; live
ASR deferred while recording continued, exercising full replay after Stop.

The actual UI test passed 1/1 in about 67 minutes. The saved result is completed,
has `transcriptIsComplete=true`, 8,863 final segments, five speaker labels, no
failures, zero dropped samples and no audio chunks. Its timeline follows source
audio time; the UI's 34:28 meeting duration follows wall time during accelerated
input. These counts establish processing coverage, not transcription or speaker
accuracy. Post-stop processing took 30:23, including 10:36.604 for one global
Nemotron phase, exclusively after Stop.

Scalar diagnostics sampled a maximum footprint of 313.86 MiB. Separate Activity
Monitor samples at roughly one-second intervals during the latter 22 minutes of
post-processing peaked at 312.10 MiB and ended near 40.14 MiB. Neither measurement
establishes the complete run's instantaneous peak or proves absence of leaks.

### Device data-loss incident and recovery

During global diarization, the parent attempted to remove only its staged DEBUG
input using `devicectl device copy to` with `--remove-existing-content true` and
a narrow destination. CoreDevice instead cleared the AUT data container. This
was an operator error, not an application crash. The user was informed promptly.
The live application was preserved until it completed from RAM and saved the new
result. This incident invalidates an unqualified end-to-end reliability claim
for this run, despite the passing UI assertions and complete processing result.

Local backups contained all 30 prior session manifests. These, plus the new
completed result, were restored and verified byte-for-byte by SHA-256 after
copying back from the iPad. All 38 production model files were likewise restored
and verified. The original preferences were restored and compared. The ordinary
Release build from `d379b83d` was then installed, and its history/current-meeting
navigation test passed 1/1. Native screenshots were exported for inspection.
No further recording or loudspeaker playback was started.

Recovery is incomplete: four finalized CAF files from three short October 13
microphone checks, totaling 112.074875 seconds, one unfinished CAF and three
result sidecars have no accessible local copy. Their saved transcripts and
speaker records were recovered. Finder backup storage exists on the Mac but
macOS privacy denied shell enumeration; a usable device backup was not verified.
Private recovery material remains in ignored local storage. Never use the
CoreDevice removal flag for container subdirectory cleanup.

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
