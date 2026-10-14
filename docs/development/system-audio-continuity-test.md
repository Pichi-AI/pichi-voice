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

## Prepared browser fixture and automatic end barriers

The original manual browser fixture remains available without query parameters. For the bounded
continuity trial, [meeting_continuity_fixture.py](../../tools/meeting_continuity_fixture.py) serves
only the fixture HTML and explicitly named synthetic WAVs on `127.0.0.1`. It does not serve the
protocol root, recordings, profiles, outcomes, or arbitrary files. It never starts capture,
launches or terminates a process, operates UI, requests permissions, or loads a model.

First run this tiny offline slice with private mock ready/ack files. It plays no audio and starts
no native capture:

```bash
python3 -S tools/test_meeting_continuity_fixture.py \
  FixtureTests.test_first_phase_slice_automatic_end_drains_then_retains_native_clock
python3 -S tools/test_meeting_continuity_fixture.py
```

Before a new hardware trial, review the concrete operator sequence and obtain a new coordinated
UI/audio lease. An earlier unsuccessful run or expired lease does not authorize another trial.
Keep the existing native 100-second trial and 60-second phase bounds. Use a fresh UUID, an owned
canonical protocol root with mode `0700`, and a separate explicit synthetic stimulus directory.
Start the helper before native capture creates any protocol files:

```bash
set -euo pipefail
pichi_fixture_token="$(python3 -S tools/meeting_continuity_fixture.py token)"
python3 -S tools/meeting_continuity_fixture.py serve \
  --root "$pichi_capture_root" --run-id "$pichi_capture_run_id" \
  --token "$pichi_fixture_token" --port "$pichi_fixture_port" \
  --stimulus-dir "$pichi_stimulus_dir" \
  --wav browser-before.wav --wav browser-after.wav
```

The placeholders are local operator values, never committed paths. Keep the server owned by this
trial and join its shutdown afterward. Open this URL in the owned isolated browser through CUA:

```text
http://127.0.0.1:PORT/meeting_browser_speech_stimulus.html?runID=UUID&token=TOKEN&phase=browserBefore&stimulus=browser-before.wav
```

Click **Prepare received WebRTC speech** before starting native capture. Preparation decodes the
WAV and connects the local peer pair behind a playback gate. It sends no speech. Save and inspect
the native screenshot immediately. Only after the browser shows **Prepared** and the process
identity and other operator artifacts are ready should the parent start native capture. This
keeps model/tool preparation outside the native 100-second interval.

Use this sequence without extra state fetches between a known action and its required screenshot:

1. Wait for matching `capture-ready.json`; atomically send command 1 with the actual owned browser
   identity. Require `wait-ack --sequence 1` to succeed, then use CUA to click **Play received WebRTC
   speech**, save a native screenshot, and inspect it.
2. The prepared fixture authenticates a `starting` event against native command/ack 1 before
   releasing speech. Its natural `AudioBufferSourceNode.onended` event posts `ended`. The server
   waits 0.5 seconds for the local WebRTC/PCM tail, atomically writes command 2, and waits for native
   ack 2. The page reports **Native end acknowledged (2)**. The parent checks ack 2 before closing
   the owned browser. An operator response or screenshot round trip cannot delay this end marker.
3. After actual owned browser exit, send command 3 and require ack 3. Prepare the distinct owned
   second-source process behind its existing playback gate; send command 4 with its actual identity
   and require ack 4. Authenticate its `starting` event, release the gate, wait for that exact owned
   process's successful exit, and post `ended`. The server writes command 5 after the same PCM tail
   and requires native ack 5. Stop progression on any failed command or process exit.
4. Keep the browser actually absent for at least eight seconds after ack 3. Restart only the owned
   isolated browser and retain actual launch/new PID evidence. Send command 6 and require ack 6.
   Open the same fixture with `phase=browserAfter&stimulus=browser-after.wav`, then prepare it using
   CUA. Save and inspect a screenshot after each UI action. Send command 7 and require ack 7, then
   click Play through CUA. Natural playback completion automatically writes command 8 and waits
   for native ack 8. Join capture/test teardown and owned fixtures before releasing the UI slot.

The parent still owns every UI action and screenshot. These events are synthetic stimulus
barriers, not proof that sound reached the persisted system track; the unchanged native PCM,
metadata and optional ASR assertions establish that result. The server only emits the expected
end command after matching native begin evidence. It rejects wrong tokens/runs, stale or changed
ready files, duplicate/skipped phases, symlinks, and unexpected acknowledgements. A failure stops
progression. Its private `fixture-events.jsonl` retains native begin/end clocks and the drain
receipt; Python elapsed times are diagnostic receipts and never substitute for native PCM clocks.

The read-only CLI gate exits nonzero on a missed, stopped, invalid or skipped acknowledgement:

```bash
set -euo pipefail
python3 -S tools/meeting_continuity_fixture.py wait-ack \
  --root "$pichi_capture_root" --run-id "$pichi_capture_run_id" --sequence 4
python3 -S tools/meeting_continuity_fixture.py event \
  --port "$pichi_fixture_port" --run-id "$pichi_capture_run_id" \
  --token "$pichi_fixture_token" --phase secondSource --event starting
# Release the parent-owned playback gate here, then join the exact owned process.
wait "$pichi_owned_player_pid"
python3 -S tools/meeting_continuity_fixture.py event \
  --port "$pichi_fixture_port" --run-id "$pichi_capture_run_id" \
  --token "$pichi_fixture_token" --phase secondSource --event ended
```

The parent must set `pichi_owned_player_pid` from the actual gated child it owns; never wait for an
unrelated PID or infer playback completion from a fixed sleep. Do not continue after a failed
gate using a semicolon-separated command sequence in a shell without `set -e`. Ack failures,
protocol deadlines and actual process exit failures are test failures, not reasons to expand the
native limits or claim a capture pass.
