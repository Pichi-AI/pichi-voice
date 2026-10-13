# FluidVoice 1.6.11 integration rehearsal

## Exact inputs

This rehearsal integrates the [stable FluidVoice 1.6.11 release](https://github.com/altic-dev/FluidVoice/releases/tag/v1.6.11), published October 12, 2026, into the current reviewed desktop downstream. It does not incorporate unrelated unfinished feature branches or the iPad prototype.

| Input | Revision |
| --- | --- |
| Downstream main before merge | `0295cd829f0389f928567d52eb36b21cb32469a9` |
| Previous shared upstream baseline | `7daffb529fb9f7c8d075f686a2d3da34695a66e4`, 1.6.10-beta.8 |
| Upstream release and fetched main | `9bf99b4f51839c6927022ed76630533b0329fa32`, v1.6.11 |
| Merge commit with initial adaptations | `39604ecb87448465707a865b897fe5a44cd7ea9f` |
| Final application code reviewed independently | `41a009a25360696e17843b59bc2535def0980391` |
| Task branch | `codex/upstream-sync-e87ff15e87` |

The upstream delta contains six commits and changes 26 paths. Fourteen paths overlap downstream changes; 358 other downstream-modified paths are untouched by this upstream batch. These counts describe this particular pair of revisions, not a guarantee about the next update.

| Upstream commit | Change |
| --- | --- |
| `262b9dfb` | Claude temperature compatibility |
| `c005f2aa` | Route duplicate/bypassed logging through DebugLogger |
| `fa5b9098` | Match native button click areas to their visible shapes |
| `1b3cba25` | Prompt cancellation of queued meeting model preparation |
| `d0b5e8ae` | Optional hold-Space dictation mute |
| `9bf99b4f` | Stable release version/build metadata |

Most larger features advertised in 1.6.11 were already present in our beta.8 baseline. Upstream meeting summaries were already disabled; this batch does not remove the downstream's separately implemented Russian meeting summaries.

## Conflicts and resolutions

### One textual conflict, three hunks

`Sources/Fluid/Theme/NativeButtonStyles.swift` conflicted in the primary, accent and inline button styles. Upstream added `.contentShape(self.shape)` to fix click targets. The downstream uses `theme.palette.accentForeground` so text remains readable against imported accent colors. The resolution retains both the shape and the downstream foreground. Choosing either whole file would lose one behavior.

The inherited native button hit-target tests exercise actual AppKit mouse events. Existing brand/palette and typography tests cover the downstream contracts. Native screenshots are separate evidence for the appearance of the exact tested app.

### Silent Xcode identity conflict

Git automatically merged `Fluid.xcodeproj/project.pbxproj` by adding a second `MARKETING_VERSION`, `PRODUCT_BUNDLE_IDENTIFIER` and `PRODUCT_NAME` to both application build configurations. Xcode accepted the duplicate settings and used the final upstream identity. The first successful unsigned Release build therefore produced a FluidVoice bundle and does not establish a correct Pichi build. The test-host lookup subsequently failed because it expected Pichi Voice Debug.

The correction keeps one version setting at 1.6.11 and retains the downstream product names, bundle identifier macros and module names. Build 28 is inherited. `scripts/dev/check-xcode-build-settings.py` now rejects duplicate keys in the project's formatted `buildSettings` blocks before a build. Its regression reproduces the silent identity override. This is a focused guard for these formatted blocks, not a general OpenStep parser.

After any upstream version bump, check the resolved build settings and the emitted app's Info.plist. A passing compile or a visible Pichi icon cannot substitute for the bundle identity check. The identifiers determine settings, model storage, Keychain services and permission identity.

### New presentation outside downstream resource contracts

The new mute indicator used a direct system font and color, and upstream added English settings, tooltip and accessibility copy without changing our catalogs. The integration uses shared typography/palette roles and adds five complete English/Russian String Catalog entries. Dynamic accessibility/help text uses the existing localization service. There is no language switch in application behavior.

### Localized overlay fit discovered in native QA

The first Russian native presentation run passed its finite-geometry assertions but the saved small-overlay image showed the new long mute label overlapping the mode label. The final indicator uses `ViewThatFits` to choose a fixed-size label or the existing icon presentation from the available waveform width. It preserves the complete localized accessibility label and tooltip. Warning color comes from the portable dark palette used for the recording surface. A small opaque theme card surface behind the shared icon preserves contrast on a bright desktop through translucent glass. This uses existing theme, spacing and typography contracts rather than a language branch or per-language font override. All four sizes in both themes were rendered and the eight final native images inspected after the correction.

### Unbounded mute history discovered in review

The new upstream timeline retained every Space mute interval and scanned the whole recording history for each packet. Ordinary typing also creates intervals. This made memory and packet work grow with the recording's length.

The existing timeline now retains at most 256 recent intervals. Evicted closed intervals become a monotone conservative excluded prefix. Recent speech keeps exact masking, and old delayed or untimestamped audio cannot reintroduce muted samples. A logical recording reset clears both recent intervals and the prefix. The deliberate tradeoff is discarding exceptionally late speech acquired before the collapsed cutoff. This needs no packet-order assumption, provider-specific branch or new audio pipeline.

The regression exceeds the retention limit and checks out-of-order muted audio, a packet crossing the prefix boundary, recent speech, unknown timestamps and reset.

## Architecture and downstream preservation

| Area | Integration decision and regression coverage |
| --- | --- |
| Russian ASR | GigaAM remains behind `TranscriptionProvider`; installed-artifact selection and provider lifecycle remain in existing service/store operations. `PichiGigaAMIntegrationTests` covers metadata, files, API and pinned meeting ASR. |
| Audio recovery and mute | Mute filtering remains inside the common capture pipeline before resampling, streaming and history storage. New `AudioRouteRecoveryIntegrationTests` combine mute with abnormal startup retry, device replacement and cancel/restart using injected hardware. |
| Upstream audio lifecycle | DirectCoreAudioInput imports only logging changes in this batch. Downstream timeout, serialized cleanup and recovery behavior are retained. `AudioHardwareRecoveryTests` and existing hotkey tests cover these contracts. |
| Meeting transcription | Existing backend registry and provider-backed assembly remain intact. Queued preparation cancellation is imported through the upstream admission queue; no model-specific coordinator factory is added. |
| Meeting captions | The existing GigaAM buffered caption engine and EOU handling remain separate from dictation mute. The public downloadable GigaAM model still reports no EOU head. |
| Local cleanup | S1-mini still uses the upstream private-provider feature contracts and native llama.cpp adapter. Its immutable pinned artifact, cancellation, download integrity and resource ownership are retained. |
| Russian meeting summaries | Existing generator, grounding, processing budget and lifetime tests remain intact. The new upstream queue does not replace this pipeline. |
| Dictionaries | Existing dictionary service, pronunciation and Russian data behavior remain intact. User dictionary content is never translated. |
| Backups | New mute preference round-trips; backups lacking it default to off. A combined regression also preserves downstream meeting defaults. |
| Brand, language and distribution | Portable appearance, typography and String Catalog contracts remain distinct from signed identity, namespaces, updater trust and analytics policy. |

No broad provider/coordinator rewrite is justified by this batch. The useful architectural correction is the bounded timeline inside its existing owner, plus small adaptations at the shared presentation and build-identity boundaries.

## Verification

Verification uses Apple Silicon, macOS 26.6.2 and Xcode 27.0. Mutable DerivedData and source packages remain in this task worktree. Synthetic audio, copied model artifacts, logs and result bundles remain outside Git.

| Check | Observed result |
| --- | --- |
| Portable checks | Passed: configuration, shell syntax, 2737 catalog keys, six catalog regressions, duplicate Xcode settings guard with three regressions, and offline synthetic Git sync regressions. |
| Corrected Release arm64 build | Passed; emitted product is Pichi Voice, bundle `ai.pichi.voice`, version 1.6.11, build 28. |
| Corrected Debug build-for-testing | Passed; product is Pichi Voice Debug, bundle `ai.pichi.voice.debug`, version 1.6.11, build 28. Local frozen signature passes deep/strict verification. |
| Full combined macOS suite | 2575 tests: 2510 passed, 65 skipped, zero failures, 163.216 seconds at final application revision `41a009a2`. The same known upstream Whisper tiny fixture remains excluded. |
| Explicit real GigaAM provider/files/API/meeting regression | Passed with a copied installed optimized model and synthetic Russian audio. |
| Default public GigaAM plus native S1-mini service chain | Passed, using an isolated pinned public model installation and synthetic Russian speech. The corrected Thursday was retained. |
| Actual S1-mini English/Russian cleanup | Passed, including correction from Friday to Thursday in both languages and no leaked reasoning/chat tokens. |
| Live Russian Qwen summary regressions | Both failed: missing explicit decision/actions/owner/deadline; missing closing unanswered question and a spurious decision. Five real-model tests in total: three passed, two failed, zero skips. |
| Untouched premerge summary comparison | Exact baseline `0295cd829f0389f928567d52eb36b21cb32469a9` fails the same two tests and the same six assertions in 19.283 seconds. Generator, transport, adapters, tests and dependencies are unchanged between baseline and integrated application code. |
| Native interactive appearance | Frozen final `41a009a2` Debug app launched and its Russian dashboard/settings were captured and inspected. Earlier `57650a79` light/dark transitions were also inspected, then theme restored. Final overlay QA at `41a009a2` separately rendered/inspected eight Russian size/theme images. This is not hardware capture evidence. |
| Live microphone, typing and meeting system-audio E2E | Not established for this copy: microphone and Accessibility are ungranted. Permission/settings visits are not capture or text-delivery evidence. |

Local result bundles are `.build/upstream-sync-evidence/full-41a009a2.xcresult`, `real-asr-cleanup-41a009a2.xcresult`, `real-models-57650a79.xcresult` and `mute-ru-41a009a2.xcresult`. Eight native UI screenshots are named `ui-01` through `ui-08`, with the application revision in each filename. No personal audio or dictionary fixture was used. The independent baseline agent preserved its two-test result in its own ignored `.build/baseline-evidence/summary-baseline-0295cd82.xcresult`.

The three positive real ASR/cleanup cases were rerun against final application revision `41a009a2`: three passed, zero failures/skips. The two negative summary cases were compared at `57650a79` and untouched main; the later changes only affect the mute view.

The matching live-summary failures strongly support an existing local model/prompt quality limitation, rather than an upstream merge regression. The observed server is Ollama 0.34.2; the tested `qwen3.5:4b` artifact digest is `d8b0f5e9760cd1682034f292d7ef72ec46f432149be0df7574bf2d6e92e38c04`. Matching failures and unchanged sources do not identify a precise root cause or prove summary quality on other inputs. The summary assertions were not weakened and the summary pipeline was not rewritten in this update batch.

The full suite also emitted 89 SwiftUI state-during-view-update diagnostics, eight background-publication diagnostics, one main-thread responsiveness diagnostic and one QoS warning. These did not fail assertions; their baseline status was not established by this rehearsal. Native UI inspection also found existing English helper steps on the Russian microphone/Accessibility permission page and a clipped brand-help sentence. The SettingsView change in this batch only adds the mute row, so those observations should be tracked separately from the new release delta.

The public repository lacks the proprietary upstream Fluid Intelligence runtime. Native S1-mini tests validate our registered cleanup provider, not that unavailable proprietary engine. Live cloud-provider behavior, hardware routes, microphone permissions, Accessibility delivery and every UI flow are outside the established passing evidence. The PR stays draft until the required release/hardware acceptance is completed.

The public CTranscribe 0.1.2 artifact contains expanded duplicate directories where a versioned macOS framework normally uses symlinks. Xcode reports a framework copy warning, and the copied signature did not validate after headers were stripped. For the local signed test host, the framework was reconstructed from the pinned artifact's canonical `Versions/A` contents using standard links and signed together with the app. No dependency source, system trust setting or permission database was modified. Signed copies are frozen before runtime testing. No valid local development/distribution signing identity was available, so these are ad-hoc test copies and do not establish stable permission identity or a distributable signed release.

The automated test host was built using `build-for-testing` with isolated `.build/Xcode` and `.build/SourcePackages`, then run using `test-without-building` against the frozen products. The format-2 `.xctestrun` test/host environments set `FLUIDVOICE_MIC_PHASE1=disabled` and `PICHI_INTERFACE_LANGUAGE=en` to keep ordinary UI/audio startup out of automated regressions. The separate presentation run sets the interface language to `ru`. Real-model paths are supplied only in ignored local test-run files. Do not apply the disabled hardware gate when performing an explicitly planned microphone/hardware probe. The known Whisper tiny fixture uses the same exclusion as `scripts/dev/macos.sh test`.

The initial test host launched from the Documents worktree stalled in dyld before XCTest began. A separately frozen signed runtime under local task artifact storage launched, but a later test stalled opening its source-relative WAV fixture in Documents. The parent moved only this task's worktree into local Codex worktree storage and rebuilt there. No OS permission or trust setting was changed. The exact operating-system cause was not established. Earlier stalled attempts are not counted as test passes.

## Independent review

The independent reviewer inspected the final integrated application code at `41a009a25360696e17843b59bc2535def0980391`, compared against both input histories, ran portable checks and reported no remaining material findings after the bounded timeline and localized overlay fixes. Review included extension-point reuse, common model/brand/language hardcoding, duplicated pipelines, immutable artifact selection, cancellation, resource ownership, source registration, identity boundaries and upstream merge impact. Review itself did not exercise hardware or model inference.

## Repeatable next update

1. Verify the latest stable release and compare its full SHA to current `origin/main`. Check for an existing update PR before preparing another.
2. Run `bash scripts/dev/prepare-upstream-sync.sh <release-tag>`. The helper reports and freezes both fetched inputs, validates upstream ancestry and creates an isolated branch/worktree. Passing no argument intentionally selects fetched upstream main, including unreleased commits. On this Mac, use an execution-accessible worktree root outside Documents, for example `PICHI_VOICE_WORKTREE_ROOT="$HOME/.codex/worktrees/pichi-voice" bash scripts/dev/prepare-upstream-sync.sh <release-tag>`. Runtime fixtures that use `#filePath` also need access to the source worktree. Moving an existing worktree requires rebuilding and refreshing generated package paths.
3. Work only in the printed directory. Record conflict paths and resolve individual behaviors. Review all overlapping automatically merged paths, especially Xcode settings, ASR, hotkeys, backup data and newly added UI.
4. Run `bash scripts/dev/check.sh`. Check actual Debug/Release product names, bundle identifiers, version and build number after compilation. Keep native packages and build directories isolated.
5. Run the combined macOS suite and explicit real-model regressions on approved or synthetic inputs. Report skipped tests separately. If a real-model case fails, compare the exact same input/configuration against the untouched premerge baseline before attributing it to upstream or changing assertions. Freeze a correctly signed copy before interactive tests, and save/inspect native screenshots for every step.
6. Run an independent review of the integrated revision, fix material findings and rerun affected checks. Record exact revisions and remaining limitations in a new update report.
7. Push only the task branch to `origin` and open a draft PR. Merge after review and required verification; never auto-merge upstream into shared main or replace the user's working app as part of an update check.

To reproduce this merge's original inputs exactly, create a new task worktree with `bash scripts/dev/new-worktree.sh upstream-replay 0295cd829f0389f928567d52eb36b21cb32469a9` and merge `9bf99b4f51839c6927022ed76630533b0329fa32` with `--no-ff --no-commit` there. The helper's offline synthetic-Git tests cover release pinning, frozen downstream bases, invalid ancestry, no-update behavior and preserved conflicts.

A local Codex thread automation was enabled for a daily 09:00 check in the user's local time. It prepares a branch and draft PR for a new stable release, avoids duplicate PRs, records verification limitations and leaves the merge for review. It requires the local execution host and repository access to be available; creation is not evidence that a future scheduled run has executed.
