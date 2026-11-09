# Streaming meeting processing

New meetings use continuous recognition and speaker processing for both in-room and online-call
capture. This is a meeting policy, independent of the selected speech model or a legacy stored
processing preference. Backend admission validates the selected model, language and source
topology before capture; unsupported requests never silently become after-recording jobs.
Recognition, text privacy and speaker attribution share the existing meeting pipeline,
resource owners, session store and native capture engines.

Every model offered for meetings must register the same live input contract: bounded microphone
and multi-track PCM, progressive ASR observations and continuous speaker processing. Provider
adapters own language, artifact and inference differences. New providers must not introduce a
separate capture loop, caption-only model substitution or a hidden full-recording pass at Stop.
Explicit retained-file retries continue to use the saved recording's processing recipe.

## Why continuous speaker state

Nemotron uses an arrival-order speaker cache and a recent-frame FIFO. Resetting its state for
each ASR phrase loses the meaning of speaker slots. One attempt therefore owns one diarizer
state from the first sample through the final right-context flush. Speaker slots identify
anonymous voices within this attempt; they do not establish people's names or the owner's
identity.

The registered streaming profile is the pinned FP16 fast128 Core ML artifact with CPU-only
execution. On the physical A10X iPad, isolated diarization of 180 seconds took 46.6 seconds
with a sampled application footprint peak of 243 MiB. These are model-only measurements;
they do not establish joint ASR/privacy throughput, attribution quality or battery cost.
The fast128 input-buffer latency is 10.56 seconds before inference time. Its throughput is
more suitable for the old iPad than the measured fast32 variants, at the cost of later labels.

Sources: [NVIDIA model card](https://huggingface.co/nvidia/Nemotron-3-Diarization),
[Core ML conversion](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml),
[diart incremental, overlap-aware alternative](https://github.com/juanmc2005/diart).

## Processing and publication

```mermaid
flowchart TD
    PCM[Native mono 16 kHz capture] --> Queue[Bounded PCM transport]
    PCM -->|Only when audio saving is enabled| Files[Existing audio writer]
    Queue --> Worker[One prepared inference worker]
    Worker --> Diarizer[Persistent speaker cache and FIFO]
    Worker --> ASR[Bounded progressive ASR windows]
    ASR --> Privacy[Existing contextual privacy admission]
    Diarizer --> Tail[Protected word attribution tail]
    Privacy --> Tail
    Tail --> Store[Session checkpoints and live presentation]
    Tail -->|Acknowledged acoustic retention floor| Diarizer
```

* Capture uses one monotonic sample clock. Native word timestamps retain their original
  values and identities. An ASR window identity differs from the continuous speaker epoch.
* The logical stages run concurrently with capture, while expensive inference operations
  run cooperatively in sequence. Two independent tasks must not compete for model residency.
* A prepared ASR session and one diarizer remain inside their original resource scopes.
  The command controller joins both scopes on success, failure and cancellation.
* PCM windows are at most 20 seconds; the transport charges queued and in-flight audio
  against one 60-second budget. There is no complete AAC archive in streaming mode.
* Acoustic processing progress does not prove that ASR recognized the same prefix. The
  adapter reports an explicit ASR stability cursor, including sealed silence windows.
* Privacy admission precedes display and persistence. The existing lexical tail can span
  ASR windows. Previously admitted text is never sent through redaction a second time.
* Only protected words covered by both the ASR and acoustic cursors enter attribution.
  Neighbor and short-interruption rules reuse the canonical policy. A finite future context
  permits revisions; ambiguous evidence eventually remains explicitly uncertain.
* Speaker-only patches apply to the latest stored segment. They preserve current text,
  native timing, privacy status and completeness. Session speaker aliases remain session data.
* Native callbacks can publish safe metadata and checkpoints but cannot recursively submit
  commands to their own worker. Eviction is acknowledged after publication, outside callbacks.

The protected pending queue and attribution tail have independent word, text-byte and
activity limits. A long pause alone is not a failure. Input gaps, exhausted budgets,
unsupported native timings or failed inference stop the attempt explicitly and preserve
completed protected text. There is no silent frame dropping or hidden full-audio fallback.

## Capture admission and interface work

The capture owner freezes the request and completes required installation, permission and
audio-session checks. Native model loading then belongs to the processing attempt, rather
than a throwaway ASR warm-up before microphone activation. Streaming preparation begins
when the first progressive PCM window arrives. The existing bounded transport holds initial
samples during preparation; it does not add a second audio queue. Both PCM modes prepare
their pinned privacy capability before publishing recognized text. Cancellation joins native
preparation even when the underlying load cannot stop cooperatively. Hardware activation
and first-time permission prompts still have real latency.

Protected transcript history is separate from the bounded acoustic and privacy working tails.
The interface can retain every approved word while model context stays bounded. Reading
projection and paragraph composition run outside MainActor, with generation checks before
publication. Lazy lists render visible paragraphs. Health-level changes do not invalidate
saved transcript reading caches. Manual scrolling pauses automatic following until the user
returns to the bottom or explicitly requests the latest text.

Speech redaction applies to recognized transcript content, including correction text and
external identity suggestions. Explicit participant aliases, meeting titles and input display
metadata remain user data. Renaming a participant or title does not change transcript bytes
or rerun NER over the meeting. Transcript edits and speech publication keep their privacy
admission; metadata exemption does not authorize publishing new unprotected words.

## Stop, retained audio and compatibility

Normal Stop joins native capture, queued inference, the diarizer's final context and the
privacy/attribution tail. It does not repeat diarization over the whole recording. The session
coordinator merges the final checkpoint before creating the processing result.

Audio saving remains an independent capture setting. When enabled, the existing writer
receives the same capture alongside the bounded consumer. A later retained-file retry uses
the pinned recording mode and profile. When disabled, audio remains in bounded memory and
cannot be recovered after process termination.

Missing mode fields in old serialized sessions still decode as `afterRecording`. The new
meeting default does not reinterpret saved sessions or checkpoints. Legacy configuration
identities remain unchanged; streaming identities include the mode and exact model profile. An
unsupported backend or source topology is rejected before permissions and preparation.
Online calls use the registered bounded multi-track input with one shared inference owner.

## Enrolled owner identity

An attempt freezes the existing enrolled reference and collects bounded, disjoint clean
voice excerpts alongside the continuous speaker state. Verification runs after the acoustic
worker closes its ASR and diarizer scopes. It is a final identity refinement, not a live claim
that an anonymous slot belongs to the owner. Only an accepted comparison marks an existing
participant as the local user. Protected words, native timing, stable IDs and explicit aliases
remain unchanged. Missing, insufficient, ambiguous or inconsistent voice evidence retains an
ordinary participant label.

Enrollment, encoder installation and the private profile store use the existing service
operations. Streaming never enrolls a meeting voice automatically or downloads an optional
encoder before admitting capture. The composite attempt identity includes the evidence
policy. Exact older anonymous streaming recipes remain resumable with owner verification
disabled, even if a profile has since been enrolled. See the owner-identity contract in
[mobile meetings](mobile-meetings.md#streaming-owner-voice-identity).

## Continuing participant reading convention

The displayed transcript assigns a short mixed insertion to the continuing main participant.
For `A / mixed / B / mixed / A`, the complete bounded insertion reads as A. The closest clean
participant before the interruption owns the pending bout; an older participant cannot claim
it merely by appearing inside the insertion. A clean `A / B / A` exchange remains three turns.
At a genuine change of participant, an unresolved short prefix can still follow the incoming
participant under the existing neighbor rule. Missing audio, manual corrections, incompatible
tracks or speaker epochs, temporal conflicts and long insertions block inference.

This is a reading convention, not source separation or proof of who spoke each recognized word.
Labels show plain participant names. They do not show multiple-speaker, interrupting or
estimated annotations. An unresolved passage without defensible context retains the ordinary
unknown-participant label. Word times, raw candidate voices and overlap evidence remain intact
in the canonical JSON. A shared batch projection supplies history, live captions, desktop,
text export, CLI labels and summary citations. Reading an archive never rewrites its manifest.

New attempts freeze `enableMainSpeakerContinuation` in their attribution policy. Missing keys
decode to false, preserving old checkpoint identities and processing on resume. The current
reading projection can apply the convention to old archives independently of their raw evidence.
Legacy inferred identities cannot act as independent anchors for another contextual guess.

## Verification boundaries

Model-free contract tests cover PCM continuity, explicit stability cursors, privacy boundary
holds, bounded protected history, long silence, late speaker revisions and joined native
cleanup. The opt-in mobile E2E test separately measures paced joint inference, pre-Stop safe
publication, native word preservation, no-audio-file behavior, resource samples and Stop tail.
Detailed profiling is explicitly gated and records scalar timing/resource metadata.
The paced diagnostic also records configuration admission, synthetic capture-command latency
and bounded MainActor queue-entry samples, separated from utility continuation delays and
sampling gaps. Phase aggregates separate capture, Stop and metadata saves from the test's
own synchronous artifact checks after completion. Queue-entry samples measure scheduler
availability, not physical touch latency or rendered frame rate. Startup diagnostics distinguish command
admission, capture request and capture return without recording speech or participant names.

Short recordings need not emit a complete protected word before Stop. Longer paced tests
must observe protected canonical output during capture and final cursor convergence. Silence
tests include long empty intervals and a returning voice, and are scored separately for
hallucinated text, participant continuity and identity verification. A successful test runner
exit alone does not establish any of those quality measures.

Automatic Fathom annotations are a weak comparison reference, not manually verified DER
ground truth. One ASR stream also cannot reliably recover both word sequences in overlapping
speech. Contextual reading ownership remains an evidence-gated heuristic rather than source
separation or proof of the words spoken by each voice.
