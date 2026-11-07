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
- Speaker labels are ON.
- No existing meeting is recording or processing.

English and Russian app action labels come from the current String Catalog; test
navigation otherwise uses the existing accessibility identifiers. The system
share action has its normal English/Russian label. If a system version presents a
different tree or action, inspect the failing native screenshot before adapting
the test. Do not add an app probe to bypass it.

## Actual UI flow and evidence

The test snapshots the existing history identifiers, inspects the real settings,
returns to Meetings and presses the real Start action. Once capture is active, it
records for at least 300 seconds. At second 10 it activates system Settings,
checks that Settings is foreground and the AUT is actually running in background,
and keeps checking AUT liveness and owned player playback. It does not reactivate
the AUT to inspect hidden UI during the background interval.

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
