# Opt-in real system-audio continuity test

`MeetingSystemAudioContinuityHardwareTests/testSystemAudioSurvivesExternalBrowserRestartWhenEnabled`
uses the real `MeetingCaptureEngine` and a private `MeetingSessionStore`. It skips in the normal
suite. `MeetingSystemAudioContinuityProtocolTests` validates the phase evidence without hardware.
The system-audio probe does not launch or kill applications, operate UI, request permissions,
change preferences, or download models. The parent interactive session owns all external stimulus.

Before running, build and normally sign the exact revision, verify it recursively, and freeze the
copy. Use already granted screen/system-audio and microphone permission. Keep the tested copy
unchanged. Set `FLUIDVOICE_MIC_PHASE1=disabled` to suppress unrelated app startup work. Save and
inspect native screenshots after each parent UI action. Use only synthetic approved speech. Never
terminate the user's primary browser or another session's process.

## Environment

| Variable | Meaning |
| --- | --- |
| `PICHI_SYSTEM_CAPTURE_CONSENT` | Exactly `1` to enable this test |
| `PICHI_SYSTEM_CAPTURE_ROOT` | Fresh absolute child of this compiled worktree's ignored `private_assets`, user-owned mode `0700` |
| `PICHI_SYSTEM_CAPTURE_RUN_ID` | Fresh UUID, included in every command and outcome |
| `PICHI_SYSTEM_CAPTURE_DURATION_SECONDS` | External phase deadline, default `100`, allowed `60...180`; completion of all eight commands ends capture sooner |
| `PICHI_SYSTEM_CAPTURE_GIGAAM_MODEL_DIR` | Optional absolute path to installed pinned model artifacts; no download/default change |
| `PICHI_SYSTEM_CAPTURE_EXPECTED_TEXT_JSON` | Optional JSON map with exactly three distinct nonempty phrases keyed `browserBefore`, `secondSource`, `browserAfter`; requires model path |

For example, the phrase map can be:

```json
{
  "browserBefore": "Первый участник обсуждает новый проект",
  "secondSource": "Другой источник продолжает разговор",
  "browserAfter": "Браузер вернулся и запись продолжается"
}
```

The probe validates system metadata, finalized nonempty finite CAFs, separate microphone/system
tracks, no terminal capture interruption, and a valid speech signal separately in each persisted
phase window. When configured, it transcribes each cropped phase independently through the existing
pinned provider with joined preparation/cancellation/unload. This test does not mark the meeting
processed or establish live coordinator/UI behavior.

## Atomic command/ack protocol

Wait for `capture-ready.json` with the matching run ID. It includes the session directory, capture
start and ready host seconds, and the bounded phase deadline. Then atomically replace
`phase-command.json`, using UTF-8 JSON with these fields:

```json
{
  "runID": "REPLACE-WITH-THIS-RUN-UUID",
  "sequence": 1,
  "action": "begin",
  "phase": "browserBefore",
  "bundleID": "com.google.Chrome",
  "executablePath": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "processID": 12345
}
```

Wait for `phase-ack.json` with the same run ID and sequence before playback or the next command.
The ack's `machAbsoluteHostSeconds` is sampled by the native test. Do not substitute wall clock,
`Date`, or `mach_continuous_time` timestamps. Native acknowledgements use the same absolute host
clock as ScreenCaptureKit presentation timestamps. The test polls every 25 ms and bounds command
JSON to 8 KiB. An operator can prepare an owned process behind a gate, report its actual PID/path,
and release playback after the begin acknowledgement. An executable without an application bundle,
such as `/usr/bin/afplay`, must omit `bundleID` rather than inventing one.

| Sequence | Action | Phase | Additional evidence and parent action |
| --- | --- | --- | --- |
| 1 | `begin` | `browserBefore` | Actual owned isolated browser PID, bundle ID, executable path; after ack play first phrase through the browser WebRTC fixture |
| 2 | `end` | `browserBefore` | Send after first playback has finished |
| 3 | `browserExited` | Omit | Actual original PID; send only after the owned browser has exited |
| 4 | `begin` | `secondSource` | Actual distinct owned process PID and different executable path; optional real bundle ID; after ack play second phrase while browser is absent |
| 5 | `end` | `secondSource` | Send after second playback has finished |
| 6 | `browserRestarted` | Omit | Same actual browser bundle ID and new PID; send only after the owned isolated browser has restarted, at least eight seconds after sequence 3 ack |
| 7 | `begin` | `browserAfter` | Same new browser PID, original bundle and executable path; after ack play third phrase through the restarted browser WebRTC fixture |
| 8 | `end` | `browserAfter` | Send after final playback has finished; engine stop and writer finalization follow |

`phase`, `bundleID`, `executablePath`, and `processID` may be omitted when the table does not require
them. Each speech phase must have positive duration at most 60 seconds. The operator's process
evidence is retained in the outcome; the test does not inspect or terminate those processes.
The external owner must retain actual launch/exit/restart evidence alongside screenshots. Wait
at least eight seconds after the exit acknowledgement before launching the new browser process;
delaying a restart marker after an earlier restart would not prove the required absence.

The real system track uses source identifier `system-audio`, capture scope `systemAudio`, and
session `applicationAudioScope=systemAudio` with no `capturedApplication`. Each phase is cropped
from finalized PCM using that chunk's presentation start plus decoded frame offset. Chunks and
forward gaps are mapped independently. Earlier overall RMS cannot satisfy a later phase assertion.
The outcome retains phase duration, decoded sample count, contributing chunks, RMS, peak, finite
sample checks, interruption counts, and optional private transcripts. A producer clock reset makes
absolute phase mapping ambiguous in this bounded probe, so it fails explicitly rather than treating
a shifted canonical timestamp as proof of speech after restart. Stream-service recovery is a
separate deterministic lifecycle test.

`outcome.json` is atomically written mode `0600`. Capture teardown is joined on success, failed
protocol, cancellation, and stop failure. Keep the outer XCTest/process watchdog for an OS service
that does not return; the cooperative operation deadline never abandons an owned capture task.
No private speech, recordings, model paths, or outcome should be committed.
