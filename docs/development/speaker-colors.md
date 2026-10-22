# Shared meeting speaker colors

## Provenance

Speaker coloring itself is inherited from FluidVoice. It is not inferred from a screenshot.
The pinned comparison is FluidVoice `v1.6.12-beta.1`, commit
`2ca292d173f0ca6ab11cfb93fb52ace83e82248e`, against downstream baseline
`6691dcffd6eff893179fc6ffc41fe9588426ce7d`.

| Layer | Git evidence |
| --- | --- |
| Original feature | FluidVoice [`5fdffdee3c1bf227cf08e769b68b3feec7134aa9`](https://github.com/altic-dev/FluidVoice/commit/5fdffdee3c1bf227cf08e769b68b3feec7134aa9), August 15, 2026, adds both the six-color palette and speaker styling. |
| Original participant chips | At that commit, `Sources/Fluid/UI/MeetingTranscriptionView.swift:2558` passes the tint; `:2995` renders the name and icon; `:3001` colors them. |
| Original transcript authors | The same file `:2589` passes the speaker tint; `:3060` renders the label; `:3092` chooses the owner accent or participant tint. Ordinary speech uses primary text at `:3102` and `:3125`. The parent commit has no corresponding per-speaker chip tint. |
| Upstream renderer extraction | `65d289eba5c41657f270560271edf114e4c73f42` moves the renderer into `MeetingSessionCanvases.swift`. |
| Pinned upstream palette | At `2ca292d1`, `MeetingSpeakerPalette.swift:9` contains six light/dark pairs; `:43` allocates positional indices, skipping the owner; modulo selects a hue. `MeetingSessionCanvases.swift:388`, `:482`, `:655` use that mapping for labels and chips. |
| Downstream theme adaptation | `614988ed992590dbb5bc959ae62ab1f4945f75a4` adds semantic readable text; `43a7c32ef772f22aa56a5e74deef17edeef82eed` resolves immutable RGB against the actual theme surfaces. The inherited RGB values remain unchanged. |
| Downstream presentation | `MeetingSpeakerPresentation` and the resolved `participantID` are downstream extensions, shared by desktop, live captions and mobile. |

The feature commit is an ancestor of both upstream `2ca292d1` and the original downstream
base `7daffb529fb9f7c8d075f686a2d3da34695a66e4`. The palette file is unchanged between
those upstream revisions. Upstream `ef74d20d70737a27bc60f734e248cdc7f9bf83b4` only
normalizes hexadecimal literal case.

## Presentation contract

The inherited six hue pairs and modulo remain the single palette. Slot allocation now uses
the complete persisted `MeetingSession.speakers` admission order. Local and merged records
reserve their slots. A displayed or reordered subset looks up the UUID in that full map;
it must never allocate colors from its own positions. Renames, generated participant
numbers and the You designation do not participate in slot selection.

The existing `MeetingPCMTranscriptBatch.mergingSpeakers(into:)` retains prior records in
place and appends new identities. Streaming state and canonical final assembly reuse that
merge. Persisted reopen restores the same array. No person database, synchronization,
settings or additional persisted schema is needed.

`MeetingSpeakerPresentation.participantIndex` carries the resolved reading owner's slot.
The paragraph resolver is shared with the full desktop/live map, including projected
leading fragments and merged aliases. It does not rewrite acoustic attribution or text.
Unresolved and competing voices keep a nil slot and neutral semantic text.

`MeetingSpeakerPalette.labelColor` resolves the palette's actual physical appearance and
uses the existing `AppTheme.Palette.readableText` with a 4.5:1 threshold on all six surfaces.
Imported themes can therefore fall back to primary text. Names and icons remain visible;
speech stays ordinary primary text. The finite palette repeats after six admitted identities.

The iOS saved-meeting smoke uses the normal root and store. Its existing Debug UI-review
boundary has a simulator-only flag to skip unrelated launch-time resource installation and
idle inference. Release and physical-device behavior are unchanged.

## Validation

Native candidate and independent code review:
`82b0d6903b575c980974c5c94c80d01407e224e5`. The frozen iOS bundle's
`AppSourceRevision` was verified against that SHA. The later fixture-only commit
`f6548462` corrects synthetic `nativePrecision` to the canonical `utterance` enum value;
both final saved-meeting runs used that corrected fixture. Production sources are unchanged.

| Check | Result and scope |
| --- | --- |
| Portable repository checks | PASS. |
| Shared palette runtime | PASS: 512 immutable RGB checks, 3072 small-label contrast checks across six surfaces and four brand variants, 256 unchanged source-fill checks, three negative controls. Admission/rename/owner/merge/filter/reopen/append contracts pass with eight identities. |
| Actual store/exporter contracts | PASS: 801 checks, 20,000 segments, including paragraph/full-map equality and merged reading owners. |
| Mobile native build | PASS: actual iOS app, hosted integration target and UI test target; arm64 simulator, Xcode 27.0. |
| Desktop native build | PASS: actual Fluid macOS scheme, arm64 Debug, unsigned. |
| iPad A16 / iOS 27 | PASS: two focused integration tests and one saved-meeting UI smoke, zero failures/skips. Live and saved light/dark frames inspected. Test sessions: 121.789 and 261.600 seconds, including frame-review waits. |
| iPhone 17 / iOS 27 | PASS: the same two integration tests and one UI smoke, zero failures/skips. Native wrapping, participant strip, authors and scrolling inspected in both themes. Test sessions: 102.641 and 252.255 seconds, including review waits. |
| Independent review | No material code/architecture findings after correction of an early color-collision issue. Independent visual review covers all 141 changed frames in contact sheets, with selected full originals reopened. |

The palette and store runs were made on `e2a1d6a4`; their relevant production source and
test inputs are identical to the native candidate. These are reused results with verified
source equivalence, not fresh runtime runs of changed logic. The native test's move into
its existing harness class fixed an initial test compilation error. The first saved UI run
was aborted after the invalid synthetic enum value produced an empty History; its original
log and screenshots are retained separately from passing runs.

Every explicit UI step was captured and visually inspected before atomically acknowledging
that exact frame and revision. Original screenshots and per-frame hashes are retained.
No screenshot review was reused on different pixels.

| Continuous native capture | Saved frames | Changed frames | Missed schedule slots | Capture errors |
| --- | ---: | ---: | ---: | ---: |
| Initial iPad run, including the aborted fixture run | 392 | 70 | 207 | 1 |
| Final iPad continuation | 55 | 16 | 16 | 0 |
| iPhone | 357 | 55 | 0 | 0 |

Simulator CLI captures missed seconds under concurrent load. This is not complete
one-second coverage, a latency measurement or FPS evidence. All successful originals
and failed-run diagnostics remain available. No speech model inference, microphone,
physical device, distribution signing, TestFlight installation or automation was used.
Real speech attribution and recognition quality are outside this presentation-only check.

Both task-created simulators were shut down and removed after independent copies of their
synthetic store and settings were verified by SHA-256. The implementation child worktree
was removed after its commits and evidence were retained. Build outputs and private package
checkout copies are reproducible and are released after preserving the verification evidence.

## Native screenshots

These are unmodified native originals from the passing saved-meeting smoke. Only synthetic
meetings appear. The user's reference screenshot, names and speech are excluded from Git.

| Device | Light | Dark |
| --- | --- | --- |
| iPad | [Native light](speaker-colors/ipad-light.png) | [Native dark](speaker-colors/ipad-dark.png) |
| iPhone | [Native light](speaker-colors/iphone-light.png) | [Native dark](speaker-colors/iphone-dark.png) |
