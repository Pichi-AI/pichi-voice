# FluidVoice 1.6.13 beta 2 integration

## Pinned inputs and release selection

| Input | Exact revision |
| --- | --- |
| Fetched downstream main | `b0b8e048c5c9acf563ac65adcf09b7932f8fbd68` |
| Latest published stable 1.6.12 | `8976f3aedc4f8fb3499a9a28c15fa29840f2b5f3` |
| Previously included beta 1 | `800ff16c1d6a24c4bfaaa61d667e6320aa3b5124` |
| Published beta 2 and fetched upstream/main | `fc59c46315f2c26568e807b6bed1de5019e42c5b` |
| Merge ancestor | `0fccdeb014462e6f82889af38c7e9de92d87a130` |
| Initial integrated source | `c0f379651347acb05d8f0b99473bfbf7d5f34305` |
| Reviewed source plus test corrections | `9ca65daf72a803cb2d5541f95ea990c70552ae6f` |
| Task branch | `codex/upstream-sync-2d7284d7f5` |

[The published release](https://github.com/altic-dev/FluidVoice/releases/tag/v1.6.13-beta.2) appeared on November 2, 2026 at 19:14:08 UTC. The paginated official release list returned 65 releases on one page. Draft, Windows and runtime/artifact releases were excluded. Stable 1.6.12 was checked independently and is already in downstream main. No open PR or published sync branch contained beta 2 before preparation. The official tag resolves directly to the exact commit above; the release has a nonempty macOS DMG. No unpublished upstream commit is imported.

Beta 2 contains stable 1.6.12 but does not descend from the beta 1 tag. The beta 1 release branch and upstream main have overlapping changes without identical ancestry. The normal merge retains both published histories through the downstream parent; it does not roll back the earlier integration. There are 59 upstream commits outside the pinned downstream baseline. `prepare-upstream-sync.sh v1.6.13-beta.2` created an isolated worktree and exposed 53 conflict paths. Main was not edited.

## Conflict decisions

Each path below combines the upstream change with the existing downstream extension/lifetime boundary. No blanket whole-side selection was used as a substitute for semantic review. Files resolving to identical downstream bytes were still inspected and explicitly marked resolved.

| Conflicted path | Decision |
| --- | --- |
| `Info.plist` | Retain trusted version/source substitutions and Pichi distribution identity. |
| `Sources/Fluid/ContentView.swift` | Keep one joined prewarm/context lifetime, admitted profile/target snapshots and independent Edit route. |
| `Sources/Fluid/Persistence/SettingsStore+CommandMode.swift` | Rename visible AI Settings copy without changing verified chat route eligibility. |
| `Sources/Fluid/Persistence/SettingsStore.swift` | Retain extracted settings declarations; add independent Edit migration and shared profile-scoped consent token. |
| `Sources/Fluid/Persistence/VoiceEngineLanguageCatalog.swift` | Use model capability metadata for 25-language speech choices and existing localized language presentation. |
| `Sources/Fluid/Services/ASRService.swift` | Retain existing shared model preparation, imported artifacts, residency and dictionary operations. |
| `Sources/Fluid/Services/AppServices+MeetingMenuBar.swift` | Open source selection before capture and retain current-profile admission and explicit audio scope. |
| `Sources/Fluid/Services/AppServices.swift` | Cancel pending picker at termination while joining existing account/model/resource shutdown. |
| `Sources/Fluid/Services/DictationContextCapture.swift` | Combine Edit reads with bounded single-reader ownership, secure/incomplete AX denial and joined cancellation. |
| `Sources/Fluid/Services/DictionaryMatchPlayground.swift` | Keep downstream provider/artifact/language ownership and dictionary presentation contracts. |
| `Sources/Fluid/Services/FileTranscriptionService.swift` | Keep frozen operation inputs and serialized export snapshots; import short-audio handling and canonical JSON alias. |
| `Sources/Fluid/Services/FluidAudioProvider.swift` | Add short inference padding without changing pronunciation/meeting alignment or loaded artifact identity. |
| `Sources/Fluid/Services/Meeting/AEC/MeetingAECOutputCommitter.swift` | Preserve opening microphone PCM while keeping epoch, retirement and timeline checks. |
| `Sources/Fluid/Services/Meeting/AEC/MeetingAECPipeline.swift` | Treat warm-up separately from failure while retaining downstream worker ownership and health. |
| `Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronBackend.swift` | Use the selected compatible model through the existing runtime and backend registry. |
| `Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift` | Retain explicit system-audio scope and strict selected-process ownership; never silently replace online audio with mic only. |
| `Sources/Fluid/Services/Meeting/MeetingModels.swift` | Retain downstream attempt metadata; add optional recordingASRModel for immutable first processing. |
| `Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift` | Freeze preferred compatible model and preserve complete artifact/options identity. |
| `Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift` | Use registered provider snapshots, selected-model pin and bounded saved-audio replay. |
| `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift` | Preserve retry owner/audio/result restoration; reset inference using authenticated retained language for explicit redo. |
| `Sources/Fluid/Services/Meeting/MeetingSessionStore.swift` | Retain existing encrypted profile-aware persistence and recovery contracts. |
| `Sources/Fluid/Services/Meeting/MeetingSummaryProvider.swift` | Keep canonical downstream summary inputs, verification and existing service operations. |
| `Sources/Fluid/Services/MenuBarManager.swift` | Carry profile plus verification ID/time on recovery events and preserve shortcut admission fences. |
| `Sources/Fluid/Services/ParakeetSpeechModelCatalog.swift` | Import 25-language metadata for Pro/Mini/Pico without renaming genuine models. |
| `Sources/Fluid/Services/PasteVerifier.swift` | Use bounded read receipts and generation/profile-qualified feedback, retaining cancellation ownership. |
| `Sources/Fluid/Services/PrivateAIIntegrationService.swift` | Reuse registered shared preparation/inference operations for independent Edit tasks. |
| `Sources/Fluid/Services/PrivateAIProvider.swift` | Keep enabled task/capability registration, S1 defaults and generic resource/token contracts. |
| `Sources/Fluid/Services/RewriteModeService.swift` | Freeze Edit route and consent; revoke across bound settings and join retired screen readers. |
| `Sources/Fluid/Services/TypingService.swift` | Retain profile/target/transport validity and joined paste verification with request identity. |
| `Sources/Fluid/Theme/Components/FluidVoiceBrandIcon.swift` | Keep the portable theme/brand artwork instead of adopting upstream distribution artwork. |
| `Sources/Fluid/UI/AISettings/DictationScreenContextSettings.swift` | Keep capability gating, shared typography and click-only permission setup. |
| `Sources/Fluid/UI/AISettings/FluidModelShowcaseCard.swift` | Combine new metadata with typed provider presentation, locale and shared theme. |
| `Sources/Fluid/UI/AISettings/PrivateAIModelPresentation.swift` | Keep downstream registered-model presentation and attribution. |
| `Sources/Fluid/UI/AISettings/ScreenContextChip.swift` | Retain localized/theme-aware context state and existing consent boundary. |
| `Sources/Fluid/UI/AISettingsView+AdvancedSettings.swift` | Import Cleanup Styles/Edit layout through shared settings/service operations. |
| `Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift` | Keep generic install/activation and provider logos; import supported speech/Apple locale choices. |
| `Sources/Fluid/UI/AppNavigationState.swift` | Change visible AI Settings label while retaining stable navigation identifiers. |
| `Sources/Fluid/UI/DashboardView.swift` | Add optional screen setup without prompting during initialization and retain private presentation fences. |
| `Sources/Fluid/UI/FileTranscriptionView.swift` | Keep immutable entry-based document snapshots and serialized profile-fenced exports. |
| `Sources/Fluid/UI/MeetingRecordingSettingsSheet.swift` | Keep the existing draft app/source operations rather than adding a duplicate selection property. |
| `Sources/Fluid/UI/MeetingSessionCanvases.swift` | Combine Home/redo navigation with private-profile concealment, summary ownership and correction/undo. |
| `Sources/Fluid/UI/MeetingTranscriptionView.swift` | Keep correction/retry ownership and choose redo languages from registered capabilities. |
| `Sources/Fluid/UI/ReleaseFeaturePreview.swift` | Use shared typography/localization for AI Settings and retain genuine model attribution. |
| `Sources/Fluid/UI/ReleaseHighlightsContent.swift` | Describe public speech/meeting/redo features; do not offer the absent proprietary Splash/Edit runtime. |
| `Sources/Fluid/UI/SettingsSearch.swift` | Retain localized capability-gated search and stable routes. |
| `Sources/Fluid/UI/SettingsView.swift` | Keep profile-aware settings and use the localized visible AI Settings label. |
| `Tests/FluidDictationIntegrationTests/DictationContextCaptureTests.swift` | Retain secure AX/OCR, cancellation and ownership assertions and add actual Edit/bound-consent coverage. |
| `Tests/FluidDictationIntegrationTests/MeetingAEC3Tests.swift` | Combine warm-up speech checks with downstream source/epoch and cleanup assertions. |
| `Tests/FluidDictationIntegrationTests/MeetingOverlayModelsTests.swift` | Retain current downstream mode/projection semantics. |
| `Tests/FluidDictationIntegrationTests/MeetingTranscriptionBackendTests.swift` | Preserve registered provider and immutable backend configuration coverage. |
| `Tests/FluidDictationIntegrationTests/ParakeetSpeechModelCatalogTests.swift` | Keep metadata/installation checks and cover expanded supported-language choices. |
| `Tests/FluidDictationIntegrationTests/SettingsNavigationStateTests.swift` | Retain stable routes and assert UUID consent invalidation across bound settings. |
| `Tests/run_meeting_backup_refresh_tests.py` | Project the canonical provider/options declarations without weakening backup refresh checks. |

The automatically merged Xcode project repeated upstream bundle/product/version keys and two DictationContextCaptureTests object IDs. Those new duplicates were removed. The downstream app remains version 0.1.0/build 36 with its configured Pichi bundle IDs, source stamp, storage and credential namespaces. The upstream beta version is tracked separately in this report and the release content. Mobile distribution identity/version remain unchanged. Shared-source membership and all 13 Xcode build-setting blocks validate.

## Architecture and semantic corrections

- Providers, supported languages, artifact validation and inference construction remain in the existing registries/adapters. Recording now persists optional `recordingASRModel` alongside the existing backend/digest so the first processing cannot follow a later UI model selection. Older records with no field remain readable. Language presentation is metadata-driven and does not depend on the interface language.
- The new upstream Edit task owner reuses PrivateAISettingsSession, PrivateProfileOperationOwner and PrivateAIIntegrationService. The existing settings controller also changes dictation selection, so the Edit owner is limited to its own operation/status lifetime. It holds its mutation slot through joined cancellation and retires before profile defaults change. No second model/download pipeline was introduced. S1 remains the public registered default and no private Splash/Edit model is offered when its runtime is absent.
- The initial per-instance Edit consent counter was unsafe because the actual Settings view uses a bound store. A shared UUID token in the same profile/defaults scope plus synchronous notification invalidates old captures across instances. Reader joining remains mandatory. Tokens/consent are outside the typed backup schema; another profile/suite cannot change a valid capture. A negative control reverting to an instance token fails the actual bound-row probe.
- Unread dictation remains recoverable after the one-second read deadline. With automatic clipboard backup disabled, it remains an owned transient item rather than becoming intentional global clipboard content. One retained recovery lease bridges delivery completion and a later read; it is retired before another delivery, on profile retirement or after the read grace. Foreign clipboard revisions are never overwritten. Owned temporary restoration clears an empty original safely; generic oversized snapshot restoration is unchanged.
- The source picker freezes both topology-specific speaker policies and chooses the policy matching the selected source, including refresh. It retains profile, PII, audio-storage and source/microphone ownership and does not silently replace online audio with microphone-only capture.
- Language redo keeps prior transcript/language/title and saved audio on failure, cancellation or restart. Explicit language changes reset only inference working state under the existing retry owner. The authoritative language comes from the existing authenticated, confined, bounded encrypted checkpoint codec, then legacy attempt metadata where needed. Visible restored transcript language is not used to guess a valid checkpoint. Same-language failed redo resumes its compatible pin; returning to a prior language resets the incompatible pin.
- New interface keys use the existing String Catalog and shared theme/text roles. Genuine model names and user/app names remain data. The catalog validates 3,713 complete English/Russian keys, 18 native plural entries and preserved format arguments; InfoPlist has eight complete keys. No font or portable brand package changed.

## Verification provenance

The first portable check failed after 16.163s because four new leaf probes and the shared CI orchestrator were unclassified. The four inert leaf probes are registered; only the explicit orchestrator is excluded from leaf discovery, preventing recursive full CI. The registry now contains 102 probes. Forty-two registry tests passed, including unknown-runner rejection.

The first macOS build-for-testing failed after 51.805s on a stale upstream configuration type in the source picker. The second compiled production code but failed the test bundle after 78.018s on a missing `try` in a throwing profile-retirement regression. Both failures are retained. The third unsigned build-for-testing passed at `f6866d51` in 31.134s. The pinned public CTranscribe archive emits its existing framework Current-symlink warning; successful compilation is not signing/TCC acceptance.

| Check | Actual scope/result |
| --- | --- |
| Portable repository checks | PASS at `715c82fc` in 40.654s, fixed production `2667b7fc` in 52.642s and compiler-compatible `db19faea` in 52.508s and final native-fixture/capability fixes `9ca65daf` in 52.687s. |
| Generic iPhone/iPad Simulator compilation | PASS at `715c82fc` in 141.712s, after shared fixes at `2667b7fc` in 34.476s and after the compiler correction at `db19faea` in 16.856s and `9ca65daf` in 24.656s. No simulator was installed, booted or presented by these builds. |
| macOS Debug build-for-testing | PASS at `f6866d51` in 31.134s at compiler-compatible `db19faea` in 76.158s and at `9ca65daf` in 81.367s; all native test sources compiled. |
| macOS Release arm64 | PASS at `9430ac0a` in 317.025s. The affected `db19faea` Release rerun passed in 289.379s. A later metadata-only language-choice correction is being rebuilt at `9ca65daf`. Debug and Release emitted Pichi identities, 0.1.0/build 36, and their exact source stamps; these were checked from built plists. |
| Changed native standalone probes | Final coverage: all 11 selected probes PASS, with source provenance retained. Initial `f6866d51` run passed ten in 48.864s; command catalog then exposed stale Russian labels and a missing actual EditModeWindowLine projection dependency. The corrected command runner passed all 83 catalog, seven language and 468 request-admission checks in 13.669s, with 52 intercepted requests and zero unexpected URLs. Parent committed tree `45a03cb4` exactly matches the tested child tree. Other ten inputs are unchanged, so their results are reused rather than claimed as a new aggregate run. |
| Full macOS XCTest suite | First fresh run 41550843388 at `2cfc1467` failed before test execution on Xcode 26.6 type checking the existing GigaAM DCT expression; both platforms failed at the same line. The source is simplified without changing arithmetic. The corrected run 41553421759 passed iOS and repository checks but the macOS job reached its 30-minute limit in an uncancellable test fixture; no full-suite success is inferred. Four failing cases and this fixture are addressed below, with another complete run pending. Local user data is not used as a test container. |
| Independent source review | Full initial merge at `c0f37965`, corrected production delta at `2667b7fc`, test delta `f6866d51`: GO after all three P2 findings and the sequential checkpoint edge were fixed. Final test-only and real-DTO projection deltas were independently reviewed through exact `45a03cb4`, followed by the one-file compiler correction (`6b908301`, byte-equivalent to parent `db19faea`), and integrated native-failure fixes through exact `9ca65daf`, with no remaining P1/P2 findings. Source review does not establish runtime/UI acceptance. |

The first fresh CI used Xcode 26.6, while the local host uses Xcode 27.0. The pre-existing `Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMAcousticFeatures.swift:60` nested DCT basis expression exceeded the older compiler's type-checking budget. Explicit Int closure arguments, Float return types, Double.pi and an intermediate angle preserve the exact arithmetic order; no compiler timeout was raised and no check was skipped. The actual baseline/current extractor and unchanged Accelerate frontend produced identical bit patterns at both -Onone and -O for 13 deterministic valid PCM inputs and eight invalid inputs: 21,320 feature values and 520 means per mode. Eight existing acoustic dictionary XCTest cases passed with no skips. API, thresholds, normalization, profile/extractor version and model weights are unchanged. Local macOS/iOS builds are repeated, and the older fresh CI compiler remains a separate gate.

The second clean CI produced an untruncated final log with 1,912 passed cases and four failed cases before its 30-minute job limit; no complete suite summary exists. Its actual last started case was `testInterruptedLanguageRetryPreservesCompletedTranscriptAndFailure`. A bounded in-progress log had ended earlier in hotkey routing, which was not the actual stop. The new retry test awaited joined shutdown before opening its deliberately uncancellable fake processor gate. The test now launches owned shutdown, observes cancellation, proves it remains joined, opens the gate and awaits both tasks before directory cleanup. Production shutdown was not weakened and no test timeout was raised.

The other native failures exposed: a stale filter expectation that omitted the explicit relaunch-recovery flag; a frozen factory expectation missing artifact directory/SHA; a stale assertion requiring raw manifest errors where downstream deliberately exposes typed `historyUnavailable`; and a real language-choice omission. Registered Whisper Tiny supports Chinese but the chooser used the onboarding-only model shortlist, which intentionally excludes Tiny. The chooser now projects available registered capabilities through the existing catalog formatting, without expanding onboarding. Tests retain complete configuration equality, strict initial PID/wrong-bundle/ambiguity checks, partial-valid and last-good full-history snapshot checks. The narrow six-file delta was independently reviewed at `9ca65daf` and locally compiled for macOS/iOS before the next full native run. Remaining results are recorded after that run completes.

The child probes retain their own inputs/provenance: 49 ASR metadata/configuration assertions; 21 Edit task ownership controls; 50 consent/bound-row assertions in each of two Swift 6 isolation modes plus an effective negative control; 17 private-pasteboard receipt cases, 31 backup and four filename cases; 286 typing checks; 29 context/profile assertions in each mode; 82 private-feedback checks in each mode with negative controls; 128 parallel export document/service operations and exported-module native-test typechecking; 15 source-scope and 23 snapshot controls plus actual encrypted-checkpoint sequential reset/resume probes. These are bounded tests, not real-model quality measurements.

The selected parent standalone run uses a private Foundation home proven before execution, separate compiler caches and private pasteboards. It does not read the user's screen, send real keystrokes, record audio or load speech models. Native XCTest runs on a fresh host because inherited singleton/defaults tests must not use the working app's data. No local full-suite result is inferred from build-for-testing.

## Remaining acceptance and distribution limits

This is a draft update, not release/main approval. New source-picker interaction, language redo with real saved recordings, left/right shortcut recording, delayed paste in actual editors, live system/microphone capture, permission identity and light/dark Russian layouts still need acceptance on an exact validated frozen signed copy. Prior beta 1 hardware/caption tests keep their old SHA and are not presented as beta 2 evidence.

The generic mobile build proves compilation only. Any changed mobile runtime path must follow simulator screenshots/review before physical iPad/iPhone checks. No active device recording was replaced. Proprietary Fluid Intelligence/Splash/Edit runtime behavior, model-download updates, real multilingual Pro quality, physical Intel execution and performance/battery/thermal behavior are outside the measured scope. No application was installed or replaced and no personal model/dictionary/audio/credential input was committed.

## Future update procedure and resource handoff

1. Resolve every published stable/beta tag to its exact commit and inspect topology. Sibling release branches can repeat changes without shared ancestry; neither version labels nor a clean merge prove preservation.
2. Keep extracted settings/provider/resource boundaries. Apply upstream fields through the existing extracted files and registries rather than restoring the upstream monolith or adding a per-model common-layer switch.
3. After automatic project merging, check trusted bundle/product/version settings and repeated source object IDs, then validate the generated mobile source membership.
4. Test consent through the real bound Settings path, not only the shared singleton. Check revocation, off/on, profile generation, backup restore and joined late readers.
5. Test language redo against a real retained encrypted checkpoint, including sequential failed/canceled redo and return to the prior visible language. Preserve audio and old results while the new attempt owns inference state.
6. Include the supported CI compiler in native verification. If inference-heavy arithmetic compiles only on a newer compiler, make types/evaluation boundaries explicit and verify actual DSP bit parity; do not raise type-check budgets to hide the problem.
7. Pin the code before combined checks/review. For later source/test/docs deltas, repeat the checks they invalidate and record exact equivalence for reused results. Keep stale failures and their artifacts.
8. Publish only the task branch to origin and leave the PR draft until remaining acceptance is complete. Never auto-merge or replace the working application.

All implementation workers used separate worktrees/branches and the parent integrated committed contents into the normal merge. Their test processes and owned worktrees were cleaned after independent hash preservation; recovery refs and lightweight receipts remain. The parent owns only its new sync worktree, build/package directories and ignored evidence. Existing user runtimes, recordings, model stores, backups and other sessions' resources remain untouched. Final parent cleanup/retention status is recorded in the private handoff.
