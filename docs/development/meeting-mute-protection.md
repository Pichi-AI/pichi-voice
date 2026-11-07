# Meeting microphone admission on macOS

Online recordings start with microphone recording enabled. An explicit rendered mute transition pauses microphone admission; an explicit rendered unmute transition resumes it. The last state survives hidden controls, unavailable observations, missing permissions and snapshot timeouts. There is no checking/unknown product state. In-room recording and meeting playback retain their existing behavior.

The existing microphone icon is a button in the recording canvas and compact pill. It controls
only recording the local microphone in Pichi, without changing the conference's microphone or
the other participants' audio. A manual pause lasts for the current recording until the user
enables it here. Conference unmute and temporary PTT cannot clear a manual pause. Local enable
still respects a remembered conference mute. The indicator exposes the effective state, reason
and local action through localized help and accessibility. A new recording resets local intent.

## Observation paths

| Source | Transition evidence | No new usable observation |
| --- | --- | --- |
| Zoom desktop | Own enabled `onMuteAudio:` command in the Meeting menu of the bound focused call window, exact status-only Computer audio state, temporary-unmute HUD, microphone control semantics and local icon proof | Retain last state |
| Google Meet in Chrome | Pinned call window/document, microphone control semantics and local icon proof | Retain last state |
| Registered native/web modules | Call phase and own microphone selectors in the platform descriptor; validation differs by surface | Retain last state |
| Unregistered applications or system-audio scope | No owned conference transition evidence | Remain enabled by default |

The monitor remembers transitions instead of requiring constant visibility of an unmuted icon. An initial explicit muted observation is a mute transition from the default enabled state. A new recording starts a new state history. A replaced or ambiguous call window cannot silently become another selected call.

One `MeetingCallObservationService` schedules discovery and active mute observation and owns the passive PTT listener. Platform modules register contracts through `PichiCallObservation`; the [platform report](../research/communication-platforms-2026-11.md) separates observed client surfaces, provisional rules and disabled research profiles.

Discovery is bounded and cached. Control geometry follows movement and resizing without fixed screen coordinates or user calibration. Zoom can use its rendered self-audio status even when its toolbar is hidden; a small owned HUD provides temporary-unmute evidence. The existing utility polling cadence remains bounded. Pixel fallback samples only a 48 by 48 crop, classified locally at 24 by 24. No OCR, image persistence, image upload or inference model is used. Chrome's native AX role is read through the bounded reader; full screen-reader mode is not enabled.

## Audio boundary

The existing gate adds a `latchedTransitions` policy for online recordings; `freshObservations` remains available for its original contract and regression tests. The latched policy has no observation expiry or heartbeat requirement. A missing frame cannot close an enabled microphone or reopen a muted one.

The one-second owned-PCM quarantine remains bounded at 2 MiB and 256 buffers across copies, queued work and delivery. Invalid PCM and unverified acquisition timestamps are rejected. Diagnostics, persistence and live ASR share the admission boundary, with an additional writer/live recheck for retired queued buffers. Quota overflow rejects that block without changing the remembered mute state.

New macOS captures freeze `hostMonotonicV1` and one monotonic host origin before capture. VPIO acquisition anchors and native SCK/AVCapture synchronization clocks map source frames onto that recording axis before privacy admission. Adjacent proven source packets calibrate each finite frame interval; a producer, format or real source discontinuity starts a new boundary. Callback arrival time remains scheduling telemetry. Each source retains one pending packet and bounded copied PCM. The last finite packet uses the measured adjacent rate when available. Invalid timing retires intake with a reported failure.

The immutable recording/source/producer packet carrier follows PCM copies, resampling, echo processing, the writer and live consumers. The gate compares mute boundaries with the same measured interval and rechecks queued output. Mute and absent source input remain gaps, including pauses shorter than the old chunk rotation threshold. Saved chunks retain their frame-to-host mapping; canonical analysis, word publication, protected coverage, VAD and segment playback consume it once. PCM sample indices remain compact inference coordinates. The saved host end supplies duration independently of calendar changes. A retained attempt pins the clock policy and every mapping anchor. A processor that cannot consume mapped input is refused before allocating ASR. Mobile capture and older saved sessions keep their existing optional-policy defaults.

Recordings without a recording-time policy retain the legacy path. The VPIO tap keeps its continuous sample-count timestamps for the writer and ASR, while privacy admission uses its independently measured acquisition interval. The two clocks may differ by at most 20 ms. A gate-owned attachment carries that verified interval through copies with unchanged canonical timing; another gate cannot reuse it. Unproven inputs retain strict acquisition-time checks. Resampled output without the attachment uses conservative 20 ms epoch edges, and the original release waits for both clocks and the downstream quarantine margin. Small hardware drift must not progressively discard valid microphone blocks or turn them into isolated short ASR windows. A candidate that fails acquisition validation is discarded transactionally before re-anchoring; only the preceding accepted end remains the monotonic floor. Repeated rejected proposals must not move that floor or prevent the next valid interval from resuming.

Explicit mute and PTT release carry the earliest available acquisition boundary. Pending PCM after that boundary, including the existing 50 ms timing margin, is excluded. Delayed earlier boundaries narrow existing approvals. Ordinary stop refuses new grants and manual commands, drains already queued negative/historical observations through the existing gate, then closes callback delivery and preserves only the mature eligible prefix before retiring queues; abort revokes approvals. The existing VPIO path and truthful unfiltered SCK fallback provenance are retained because direct software AEC has insufficient render history for the quarantine delay.

## Temporary unmute

Space key-down alone never enables recording. A rendered temporary-unmute transition or explicit audio state must confirm it. A confirmed temporary unmute keeps its muted base state, which is restored on the owned key-up or required-modifier-release boundary. A delayed release preserves historical exclusion without overriding a newer rendered unmute. Ordinary Space while persistently unmuted does not invent mute. Stale frames from a finished PTT interval cannot reopen it. Missing HUD/control observations alone do not change the remembered state.

## Presentation and limits

The canvas and compact pill show a normal microphone while recording is enabled and a red slashed microphone with a lock while muted. The muted meter is suppressed. Localized hints describe the retained admission state rather than claiming continuous platform confirmation.

This policy deliberately prioritizes continuity of the last observed state. A completely missed transition cannot be inferred from absent UI and will leave the previous state in effect. Default enabled admission can record before an initial mute observation, and unsupported platforms cannot currently detect transitions. Rendered UI and passive keyboard delivery do not provide sample-exact attestation of the conference's internal mute boundary.

## Verification

- `bash scripts/dev/test-meeting-microphone-privacy.sh`: optimized synthetic PCM checks for both policies, long observation gaps, explicit boundaries, bounded memory and joined stop.
- `MeetingMicrophoneMuteMonitorTests`: retained states, exact rendered/HUD selectors, source pinning, temporary unmute and stale-frame fences.
- `MeetingMicrophoneWriterPrivacyTests`: actual CAF/diagnostic output across hidden-control periods and explicit mute/unmute transitions.
- `MeetingMicrophoneCaptureTests`: native tap continuity across 90 virtual minutes, independent acquisition anchors, format changes, bounded packets and joined stop.
- `MeetingRecordingClockCoreTests` and `MeetingNativeCaptureClockTests`: frame mappings, native clock conversion, finite resampling tails, VAD coverage and real gaps.
- `MeetingAnalysisManifestTests`, `MeetingLiveAudioFIFOTests` and `PichiMeetingBufferedCaptionsTests`: persisted mapping, playback inversion, copied live input and mapped word coverage.
- `MeetingAEC3Tests` and the shared-clock writer/streaming cases exercise the production composition through privacy, real CAF output, canonical publication and session reload.
- Native signed-app acceptance checks hidden toolbar, compact Zoom, temporary/persistent unmute, resizing and native indicator appearance. The user's physical Space test remains separate from injected-key tests.
