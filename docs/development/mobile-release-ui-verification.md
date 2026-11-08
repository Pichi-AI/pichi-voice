# Physical Release UI recording verification

`MobilePhysicalReleaseUITests.testReleaseTinyFiveMinuteBackgroundRecordingAndJSONShare`
is an opt-in physical-device UI test. Ordinary simulator and CI runs skip it before
activating an app or an audio session. A parent test owner must hold the explicit
device speaker/microphone lease for the entire recording. The test does not use
the Mac microphone, Mac players, injected capture, test-only app entry points or
an imported `AppServices` composition.

## Products and signing

Build and sign the UI test runner separately from the ordinary Release app. Before
testing, copy both products into private ignored storage and record their source
revision, executable SHA-256, signing identity and `codesign` verification results.
The AUT must contain no XCTest plug-ins. The runner may contain its normal XCTest
bundle. Do not rebuild, replace or re-sign either running product during the test.

For a task-owned physical runner, set `PICHI_MOBILE_UI_TEST_BUNDLE_IDENTIFIER` to
a unique test bundle identifier before building. Its default remains
`ai.pichi.voice.uitests`. This override affects only the UI test target;
the application and Live Activity retain `PICHI_MOBILE_BUNDLE_IDENTIFIER`. Do not
override `PRODUCT_BUNDLE_IDENTIFIER` globally or replace another task's installed
runner and data. Inventory installed runners before choosing the task identifier.

`PichiVoiceMobileUIAcceptance` is the Release UI-only scheme. Build it for testing
with the single requested UI selector to produce the runner and `.xctestrun`
without an embedded hosted-unit-test bundle or a testable production module.
Keep the usual `PichiVoiceMobile` scheme for unit/integration tests. Verify the
frozen AUT contains no `.xctest` before physical installation in either route.

Configure the frozen `.xctestrun` UI test entry's `UITargetAppPath` and appropriate
`DependentProductPaths` to use the exact ordinary signed Release AUT. Set the
runner's environment variables below, without copying them into the AUT's launch
environment. Keep the existing valid development identity and device profile;
do not change Apple Accounts, permissions, platform templates or the SDK.

Xcode 27's platform runner template contains `UIBackgroundModes = [continuous]`.
Setting `INFOPLIST_KEY_UIBackgroundModes` on the UI test **bundle** is insufficient:
the build system only copies `UIDeviceFamily` from that bundle to its generated
runner. See the upstream [XCTest runner task producer](https://github.com/swiftlang/swift-build/blob/main/Sources/SWBTaskConstruction/TaskProducers/OtherTaskProducers/XCTestProductTypeTaskProducer.swift).

For the owned runner copy only, add `audio` to its application `Info.plist` before
normal valid signing and freezing. Preserve the other Xcode-generated values.
Verify the signed runner's final `Info.plist` actually contains `audio`. The test
fails before playback if it is absent. Do not alter the installed Xcode template
or add private background assertions. The public audio requirement follows
[Apple's playback category documentation](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback).

Install the frozen runner, then stage an approved public synthetic Russian WAV at
this path in the runner's own data container:

```text
Library/Application Support/PhysicalReleaseUI/audio/ru.wav
```

Neither this file nor audio captured by the AUT belongs in Git. The runner loops
the WAV with `AVAudioPlayer`, starts playback while its own application is
foreground, then switches to the AUT. Its playback session uses the public
`.playback` category and `.mixWithOthers`; the AUT independently owns its actual
microphone capture. The final app's audio-off policy concerns its captured audio,
not the approved input fixture staged in a separate test runner.

Construct the player and call `prepareToPlay()` only after bringing the runner
to the foreground and activating its `.playback` audio session. Preparation can itself activate audio;
calling it earlier can fail with an iOS background activation error before the
AUT is touched. Keep preparation inside the existing owned playback cleanup.

The GigaAM system-transition selector waits up to ten seconds for each actual
foreground/background transition before its fixed background observation. A
wait does not accept a suspended or terminated recording app. It logs the
expected and observed state and the first failure before cleanup, so a cleanup
failure cannot hide the original boundary. Its owned Stop requires an enabled,
hittable control and observes that control becoming disabled or disappearing.
That is early UI admission evidence only; the normal completion check must still
join and expose the transcript. Cancellation joins a separate cleanup task;
unresolved cleanup is explicitly reported for the physical owner. Cleanup waits
up to thirty seconds for a ready owned Stop or actual processing/completion;
a temporarily disabled or missing Stop alone never counts as an accepted Stop.
Two deterministic cleanup cases cover disabled-to-ready and already processing
or completed. Three
`testPhysicalTransitionWait*` cases cover delayed state, deadline and
cancellation with a deterministic clock, separately from physical acceptance.

GigaAM and Tiny use the same owned Stop/join entry. Both wait for actual
foreground and an actionable Stop or processing/completed state, then await
completion before clearing ownership. Tiny also uses the ready Stop operation
on its success path. Five `testOwnedRecordingCleanup*` cases exercise the real
shared entry with controlled operations: delayed readiness, joining an already
processing attempt, and propagated join failure. The first two hold a join gate
to prove cleanup cannot return early. A failed Stop still attempts bounded join;
if both fail, both errors are retained. Separate cases hold the join gate after
an injected Stop failure and check combined failures. Run these alongside the existing nine
logical cases before physical audio; they do not replace device acceptance.

## Explicit gates and preconditions

Set these variables in the **UI runner** test entry only:

```text
PICHI_PHYSICAL_RELEASE_UI_SOAK=1
PICHI_PHYSICAL_RELEASE_UI_AUDIO=1
PICHI_TEST_REVISION=<exact frozen AUT source revision>
```

Select only this test and disable parallel testing. The parent must have already
resolved physical UI automation, signing/trust and microphone permission through
normal system settings. The test does not approve permission prompts. Device
speaker output must already be audible. The test uses the user's actual app
language/theme and asserts the existing UI choices rather than changing them:

- Whisper Tiny is installed and selected.
- Save audio is OFF and sensitive-data redaction is ON.
- Automatic participant resources are ready, and the parent has verified the
  underlying enabled speaker-label policy as described below.
- No existing meeting is recording or processing.

English and Russian app action labels come from the current String Catalog; test
navigation otherwise uses the existing accessibility identifiers. The system
share action has its normal English/Russian label. If a system version presents a
different tree or action, inspect the failing native screenshot before adapting
the test. Do not add an app probe to bypass it.

## Actual UI flow and evidence

The test snapshots the existing history identifiers, inspects the real settings,
returns to Meetings and presses the real Start action. Once capture is active, it
records for at least 300 seconds. At second 10 it activates system Settings and
uses the existing bounded state-wait helper to observe Settings foreground and
actual AUT background admission. The same helper observes runner/AUT foreground
activation and the later foreground return/relaunch; an immediate state snapshot
is not transition proof. Existing delayed/deadline/cancellation cases cover this
helper. Subsequent background liveness and owned player checks remain strict;
the test does not reactivate the AUT to inspect hidden UI during that interval.

After five minutes it stops the runner's player, returns to the AUT, verifies that
protected committed caption text has grown and that the latest paragraph is in
the native viewport. A real scroll gesture pauses following; the existing jump
button returns to the latest text. It presses Stop Recording, waits for normal
completion, opens the actual JSON export action and verifies the native share
sheet. There must be no audio-export action for this strict meeting.

The runner emits `export_presented` and keeps the share sheet open for 15 seconds.
The parent may copy the AUT's owned `tmp/meeting-share-<UUID>/` directory during
that checkpoint and inspect the generated JSON using ordinary device tools. The
test then dismisses the share sheet, finds the one new history UUID, terminates
and normally relaunches the AUT with empty launch arguments/environment, and opens
that persisted transcript through its history row. It preserves the meeting for
the parent's audit rather than deleting evidence.

Native screenshots are XCTest attachments named with the test, UI step and frozen
AUT revision. The parent must export and inspect them, including settings, Start,
ten-second live view, actual background, five-minute live view, follow pause/jump,
Stop, completed transcript, native share sheet and history after relaunch. Logs
record elapsed time, liveness, counts and the new session UUID, not transcript
contents. Stop the owned player on every exit. Failure/cancellation requests the
normal Stop Recording path for only the attempt started by the test and joins a
bounded cancellation-independent cleanup task. An unavailable stop or failed join
is explicitly logged for the parent's safe cleanup; it is never reported as PASS.

## Boundaries of the result

This test proves actual Release UI routing, bounded five-minute microphone capture
with an observed background state, advancing protected captions, physical scroll
follow behavior, normal completion, native JSON share presentation and persisted
history reopening. It does not directly read another application's sandbox.
Therefore the parent must independently inspect the new session's storage mode,
PII/speaker flags, state, timing, nonempty redacted segments and exported JSON, plus
the AUT's owned meeting/temporary directories for absence of captured audio files
or raw original text. Inspect background checkpoint/log timestamps to distinguish
background recognition progress from work performed only after returning.

Share presentation and generated JSON are not proof of delivery to Files or another
application. This flow intentionally does not choose an unobserved iCloud, remote
or personal folder. Separate UI delivery verification needs an observed, explicitly
local destination. A single synthetic voice does not prove two-speaker separation,
Russian PII recall, mixed-language accuracy, an hour-long thermal run or GigaAM
background performance on the 2017 iPad.

## Physical Tiny settings transaction

When the verified original settings are GigaAM, audio saving ON and PII OFF,
`MobilePhysicalReleaseUITests.testPhysicalPrepareTinyStrictSettings` uses only the
ordinary model/Privacy controls to prepare already installed Tiny, audio OFF and
PII ON. It waits for PII to become active. No recording, account, voice profile,
model deletion or OS prompt belongs to this driver.

Participants are automatic in the current mobile UI. Neither prepare nor the
recording body expects the removed `recording.diarization` switch. Both inspect
Settings > Participants and its `recording.requiredResources` readiness message.
Before either selector, the parent must verify the current saved/default
`meetingSpeakerLabelsEnabled` value and a completed session from the same frozen
AUT whose metadata has `speakerLabelsEnabled=true` and
`speakerProcessingMode=streaming`. Set these values in the runner only:

```text
PICHI_PHYSICAL_SPEAKER_LABELS_PREFLIGHT=1
PICHI_PHYSICAL_SPEAKER_PREFLIGHT_REVISION=<exact frozen AUT source SHA>
PICHI_PHYSICAL_SPEAKER_SESSION_ID=<verified baseline session UUID>
PICHI_PHYSICAL_SPEAKER_SESSION_MODE=streaming
```

These attestations are checked before preparation can mutate settings and before
the recording body acts. They do not substitute for checking the new Tiny
session's own speaker flags, mode and labels after capture. Restore deliberately
does not require new speaker evidence, so missing evidence cannot prevent undoing
the three owned setting changes. Two `testPhysicalSpeakerPreflight*` cases cover
valid evidence and missing, disabled, mismatched or stale evidence.

The physical owner must first preserve current data and verify the ordinary
frozen AUT is running and idle. In the runner only, set `PICHI_TEST_REVISION` to
that full source SHA, `PICHI_PHYSICAL_TINY_SETTINGS_IDLE_PREFLIGHT=1`,
`PICHI_PHYSICAL_TINY_SETTINGS_OPERATION=prepare`, and
`PICHI_PHYSICAL_TINY_SETTINGS_RUN_ID` to a fresh UUID. Run only the prepare
selector. A disagreement with the original settings fails before mutation.

Run the existing Tiny recording selector separately. Whether it passes or fails,
once its owned recording has joined Stop, run only
`testPhysicalRestoreTinyOriginalSettings` with operation `restore` and the same
UUID/source SHA. Do not rely on XCTest's test-method ordering. Preserve the
runner data container between these calls. A bounded receipt under its own
`Library/Application Support/PhysicalReleaseUI/tiny-settings/<UUID>.json` owns
restoration; it contains only the three settings and source/run identity.

Preparation failure or cancellation joins rollback in an independent cleanup
task. An interruption that prevents rollback leaves an explicit
`restorationRequired` receipt for the physical owner. Restoration refuses an
active recording or prompt and never stops an attempt it does not own. An
already restored receipt only verifies the original profile again. Keep the
receipt with the test evidence after successful restoration.

Four `testTinySettings*` cases exercise the transaction with deterministic fake
controls, including partial writes, cancellation, commit failure, restoration
failure and mismatched receipts. They do not establish physical UI acceptance.

Settings navigation uses the app's reselect-to-root contract and the existing
bounded reveal helper before tapping a row. It searches both scroll directions
without waiving visibility, enabled-state or prompt checks. Two
`testPhysicalControlReveal*` cases cover offscreen, ready, missing and failed-gesture
outcomes. With `PICHI_PHYSICAL_SETTINGS_NAVIGATION=1`, the read-only
`testPhysicalSettingsNavigationRevealsLandscapeRows` case also requires the ordinary
idle preflight and exact AUT revision, rotates through XCTest's public orientation
API, visits models/privacy/recording/participants across section switches, checks the original
model/audio/PII profile and returns to idle Recordings in landscape. It never
starts capture or changes those settings; run it before the acoustic cases.
