# Meeting microphone admission on macOS

Online recordings admit local microphone PCM only after a fresh observation of the selected meeting's unmuted control. In-room recording retains its existing behavior. Meeting/application playback continues independently of microphone admission.

## Supported observation paths

| Source | Current adapter | Missing or ambiguous evidence |
| --- | --- | --- |
| Zoom desktop | Native control identity, consistent English AX actions, synthetic microphone/slash shape proof | Block microphone |
| Google Meet in Google Chrome | Selected process, unique call window and Meet document, English microphone actions, synthetic shape proof | Block microphone |
| Other applications, other browsers, system-audio scope | No confirmed adapter | Block microphone |

The locator discovers the actual control and refreshes its geometry, including window movement and resizing. There are no user calibration images or fixed screen coordinates. Discovery is bounded and cached. A utility timer samples a 48 by 48 crop at 4 Hz; classification uses a 24 by 24 local representation. No OCR, model, image upload or image persistence is used. The observer uses existing Accessibility/screen-capture permissions without requesting broader access.

The attempt pins its process, window and Meet document after unique discovery. A replaced window, another call or unrecognized interface must not silently become the selected source. Restart recording after an unsupported source-window replacement. A hidden control, stale frame, contradictory semantics or missing permission yields unknown.

## Audio boundary

`MeetingMicrophonePrivacyGate` owns at most 2 MiB and 256 PCM buffers across copying, quarantine and delivery. Its one-second RAM quarantine exceeds the 0.75-second positive-observation lease. Invalid PCM and unverified acquisition timestamps are rejected. Raw microphone diagnostics, software normalization, persistence and live ASR receive only released PCM. Writer and live sinks recheck admission to exclude a delayed retired callback.

On mute or unknown, only a previously confirmed prefix ending before the last positive snapshot start minus 50 ms remains eligible. The uncertain tail is discarded. A later earlier unsafe boundary narrows existing approvals. Even confirmed prefixes complete the quarantine delay. Ordinary stop joins that prefix before retiring the runtime and writers; aborted starts revoke all approvals. Physical microphone health counters continue while intentionally blocked, without treating privacy exclusion as a hardware failure.

The existing VPIO path is used for supported speakers. Direct software AEC has insufficient render history for a delayed microphone and is excluded for privacy-gated capture. Existing SCK fallbacks retain truthful unfiltered echo-protection metadata.

A passive Space listener observes only the targeted foreground call. Key-down never grants admission. A possible push-to-talk release closes immediately, using its event timestamp independently of callback freshness. Missing timestamps, focus loss or listener disablement conservatively revoke retained approvals. Fresh muted UI confirmation is required before clearing the release fence. Ordinary Space during persistent unmute does not close the microphone.

## Presentation and limits

The recording canvas and compact pill share the microphone indicator: a red slashed microphone for detected mute, a question badge for checking/unknown and the normal microphone for confirmed unmute. Blocked states suppress the microphone meter and healthy check. Localized hints explain that microphone recording is blocked.

Observed UI state is a best-effort signal. The meeting application provides no bound on icon or accessibility updates, and passive key delivery has no hard latency guarantee. RAM quarantine reduces exposure and fails closed on missing evidence, but cannot prove sample-exact exclusion at the platform's internal mute transition. Conference-provided media or an authoritative platform integration is required for that stronger claim.

## Verification

- `bash scripts/dev/test-meeting-microphone-privacy.sh`: optimized synthetic PCM, clock, bounded-memory, prefix, delayed-boundary and joined-stop checks; no devices or files.
- `MeetingMicrophoneMuteMonitorTests`: semantics, unrelated glyph rejection, document pinning, push-to-talk fences and unsupported-source lifecycle.
- `MeetingMicrophoneWriterPrivacyTests`: actual quarantine and writer with synthetic markers, including on-disk PCM and diagnostic exclusion after revocation.
- `MeetingMicrophoneCaptureTests`: existing clock contracts plus acquisition-time privacy validation.
- Native signed-app acceptance must separately check both platforms, window geometry changes and the microphone indicator in both themes. Physical Space acceptance is performed by the user after installation; synthetic key delivery does not establish event-tap acceptance.
