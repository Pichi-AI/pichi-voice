# Onboarding integration after FluidVoice 1.6.12

## Pinned candidate

| Input | Revision |
| --- | --- |
| Downstream main before the upstream update | `59e5079066406ff2f2ecdec8c1c2395eaf69e052` |
| PR 46 application source | `0d44a14be4acdce066e2938968b0eccd1e305d8b` |
| Original PR 47 | `9be0cabe738097884ff34a8a17879c7c7d884432` |
| Combined source and desktop build | `4c430cda987b4545552b4cdeda35348ce23fac82` |
| Final mobile source | `e88179911952f1127aa9f8f056026495e4e09b8b` |
| Integration branch | `codex/pr47-integrate-20261022` |

This branch merges the reviewed upstream integration and the original onboarding PR. The original author's branch and worktree were not changed. The generated mobile project contained duplicate group objects after Git's union merge; rerunning its existing generator restored unique mobile memberships. The final mobile source adds two vertical `fixedSize` modifiers to the existing privacy captions after a real iPad screenshot exposed truncation. No model lifecycle, privacy policy, resource operation or provider hierarchy was added.

The same privacy control is reused by onboarding and Settings. Shared onboarding components use the portable brand, typography and localization contracts. Imported appearance does not change signing, credentials, storage or distribution identity. The two-caption delta from `4c430cda` to `e8817991` is mobile-only. Desktop-active tracked inputs are identical between these revisions, so desktop results retain their actual `4c430cda` provenance. The earlier PR 46 desktop binary is not equivalent to this candidate's shared onboarding changes.

## Checks completed

| Check | Actual result and provenance |
| --- | --- |
| Portable checks | PASS at `4c430cda`, 28.64s. |
| Mobile project generator | `--check` PASS; 484 unique mobile IDs, with 189 app, 4 UI-test and 24 hosted-test memberships. An identical pre-existing PBXBuildFile duplicate outside the generated mobile groups was not changed. |
| Mobile build-for-testing | PASS at `4c430cda`, 105.87s; affected mobile build repeated at `e8817991`, PASS in 18.078s. |
| Normally signed macOS build-for-testing | PASS at `4c430cda`, 124.00s. The frozen copy preserves all 19 effective Xcode entitlement keys and passes strict recursive signature verification. |
| Brand logo rendering | Standalone PASS at `4c430cda`, 5.818s. |
| iPhone native UI and hosted tests | Fresh at `e8817991`: 16 passed, 0 failed/skipped. Welcome portrait/landscape, all 14 Russian static pages in light/dark, replay/debounce, Settings and 12 setup transaction tests. |
| iPad native UI | Fresh at `e8817991`: all 14 static pages PASS in 397.45s; Settings, audio switch and rotation PASS in 419.99s. Replay and location Skip retain their successful `4c430cda` provenance, with unchanged relevant inputs. |
| Independent source/architecture review | GO for the combined `4c430cda` and the two-caption `e8817991` delta, no P1/P2 findings. Existing service operations, immutable selection, cancellation, ownership, branding/localization and upstream merge impact were reviewed. |
| Human visual review | Actual native iPhone welcome and iPad privacy frames at `e8817991` were shown to the user and explicitly accepted. The earlier PR 46 participant-picker review was also accepted. |
| Ordinary physical iPad Release | Build PASS at `e8817991`, 166.337s. Frozen Release has the exact source stamp, 50 regular files, 71,077,458 bytes, normal development signing, provisioned device and no XCTest plugin. In-place installation and launch without test arguments passed on the paired iPad. |
| Physical preservation | Independent before/after comparison passed for all 65 sessions, 187 meeting files, voice profile and 14 preferences. Index, meeting data and profile are byte-identical. No active recording or processing was interrupted. |

Simulator UI uses the existing saved-meeting-review launch mode to suppress automatic installation/inference. Native controls and state transitions are exercised; these results do not establish real first-use model preparation or inference. All 27 iPhone gates and the changed cadence frames were visually reviewed. The iPhone run retained 694 frames and 18 missed intervals. iPad evidence retained 963 frames, 310 missed intervals and 4 capture errors, including the first intentionally interrupted truncation attempt. Complete one-second coverage is not claimed.

Physical acceptance retained 16 frames with 5 unique decoded images, one missed interval and no capture errors. An independent reviewer inspected all five unique frames and confirmed normal launch/state restoration. The restored failed session already existed before installation; its data did not change. No new microphone recording or throughput trial was started on the user's iPad. The raw helper's nested historical `mainRevision` key is explicitly corrected in a separate provenance receipt: its value is the premerge candidate, not main. Raw evidence remains unchanged.

## Remaining delivery gates

The changed macOS onboarding still requires a bounded native visual smoke on its frozen signed copy. PR 46 microphone insertion/cancellation and active-caption movement are recorded separately in the upstream report. A successful candidate installation does not establish final-main installation: after reviewed merges, rebuild and freeze the exact fetched main with its source stamp, repeat the idle guard, preserve current data, install in place and verify ordinary launch/readback.

Cloud account calls, the unavailable proprietary Fluid Intelligence runtime, physical Intel runtime and previously accepted summary semantic limitations are not converted into passes by these local checks. No personal recordings, transcripts, profiles, model weights, private paths, credentials or signing identities are committed.

## Resource ownership and evidence

The parent integration session owns the two integration worktrees, frozen bundles, build directories, physical device and remaining Mac/audio checks. Delegated UI/review processes have joined. All four owned PR 46/47 simulators were shut down and deleted only after complete independent container/settings/evidence copies passed SHA256 and separate-inode verification. Original recordings, settings, voice profiles, failed attempts and native frames are retained outside those simulator directories. Shared models and the user's installed Mac app were preserved.

Private local receipts retain exact commands, source hashes, signatures, timings, native image hashes and capture limitations. Reproducible package checkouts and build outputs remain only while needed for final-main delivery; remove owned resources after verified preservation. This report must be updated with the final main revision and remaining acceptance results before declaring delivery complete.
