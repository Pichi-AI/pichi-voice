# FluidVoice 1.6.12 integration

## Pinned inputs

| Input | Revision |
| --- | --- |
| Downstream baseline | `59e5079066406ff2f2ecdec8c1c2395eaf69e052` |
| Previous upstream baseline | `2ca292d173f0ca6ab11cfb93fb52ace83e82248e`, v1.6.12-beta.1 |
| Published stable release | `8976f3aedc4f8fb3499a9a28c15fa29840f2b5f3`, v1.6.12 |
| Compiled and independently reviewed source | `9e4602a4f5f03c384bd202a966b54198814bbc1e` |
| Task branch | `codex/upstream-sync-537ab0b976` |

The release was published on October 22, 2026. Both the public release and the fetched tag resolve to the same immutable commit. The stable target includes the previously integrated beta. The existing open-PR and update-branch inventory contained no prepared integration of this SHA. The helper was invoked with the explicit tag `v1.6.12`; unpublished upstream main is not an update target.

The delta contains 12 commits and changes 157 paths. The initial merge reported 39 conflicted paths. Independent agents resolved disjoint source scopes in separate worktrees based on the same downstream SHA. Their resolved files were reviewed and imported into the parent merge. The checks below identify their exact parent candidate or the input equivalence used for a bounded rerun. Individual agents' syntax checks are not evidence of a functioning combined app.

## Conflict decisions

- Dictionary UI keeps the new manual entry, pronunciation learning, spelling correction and word-test flows while retaining the responsive downstream drawer and shared provider/service operations. User words and custom model names remain data. A pending operation prevents another word test from taking capture ownership.
- Meeting UI keeps inline text editing, batch speaker edits, Markdown export, settings/history access, shortcuts and caption dragging. Existing participant presentation IDs, native member IDs, owner labels and downstream waveform are retained. The existing separate history snapshot is reused rather than adding a duplicate class.
- Meeting domain operations retain attribution provenance and stable correction IDs. Undo restores the complete prior correction state. The upstream destructive speaker inheritance and native-member deletion are not applied to downstream native evidence. The combined pipeline/backend versions are 17/9; older mismatched processing pins remain rejected rather than silently reinterpreted.
- Capture keeps the downstream memory consumer, immutable model/artifact selection, all-system audio contract and joined cleanup. The new comparison probe is admitted only for retained audio with PII redaction off. Its constructor independently rejects private sessions before creating files. Failure and Stop join its cleanup.
- Settings remain in the existing extracted key, model and meeting preference files. Automatically merged duplicate declarations are removed. Existing GigaAM source/default selection and explicit browser-detection preferences are retained.
- Dictation keeps authoritative loaded credentials, the admitted route/target/mode snapshot, connection options and rapid-toggle ownership. The new presentation cache has no authorization role. Standard/cloud idle connection pools retain request ownership and redirect policy; bounded local sessions retain their previous lifetime rules.
- Updater rollback uses the trusted distribution repository and the existing distribution admission gate. Upstream's hardcoded application repository is not an installation destination. Disabled production updates remain disabled, including the newly introduced rollback entry point.
- The clean textual Xcode merge repeated the earlier silent identity problem: duplicate upstream product/bundle/version settings. Each app configuration now has one Pichi identity and version 1.6.12, build 34, above the downstream build 33. Mobile identity/version are unchanged. The portable duplicate-setting check covers this boundary.
- The dictionary ribbon receives colors from the portable theme. Shared native controls retain their separate iOS implementation. Existing typography and genuine model attribution are preserved. New trusted interface copy has English and Russian String Catalog entries; existing entries remain unchanged.
- The ignore file retains downstream development instructions, privacy exclusions and update reports, together with upstream local Claude exclusions. The new recovery-copy standalone probe is explicitly registered without weakening registry coverage checks.

No provider hierarchy, model-specific coordinator factory or parallel audio pipeline is introduced. Upstream notices and licensed source/artifacts are retained. No personal dictionaries, recordings, model weights, credentials or signing identities are part of the committed update.

## Verification

The initial full-suite compiled source is `9e4602a4f5f03c384bd202a966b54198814bbc1e`. The acceptance follow-up below records the later two-source picker fix and its affected checks separately.

| Check | Actual result and scope |
| --- | --- |
| Portable repository checks | PASS at `9e4602a4`, 20.631s. Registry coverage, privacy ignores, source configuration, update helper regressions and identity validation passed. |
| Standalone registry | 65 PASS, 0 remaining FAIL, 1 expected updater-UI SKIP, aggregated with per-probe provenance. The full run at `866a034e` took 450.948s with 62 PASS, 3 FAIL, 1 SKIP; affected repairs passed subsequently. The final participant-input contrast probe at `262e53af` took 45.686s. Registered coordinator projections still extract byte-identical capture/handoff and timeline declarations after the later Undo fix; those hashes are retained. The separate assembler source probe was rerun. This is not a fresh single full-suite run on the final commit. |
| macOS Debug build-for-testing | PASS at `9e4602a4`, 35.515s, all native test sources compiled. |
| macOS Release arm64 | PASS at `9e4602a4`, 279.702s, actual arm64 binary |
| macOS Release x86_64 | PASS at `9e4602a4`, 210.928s, actual x86_64 binary. Cross-compiled on Apple Silicon; physical Intel runtime is unverified. |
| Native XCTest | PASS at `9e4602a4`: 3150 passed, 0 failed, 80 skipped, 258.975s, exit 0. The inherited flaky Whisper-tiny E2E fixture remains the sole command-line exclusion. Model, hardware and private-fixture opt-ins were not enabled. Native test skips are retained in the xcresult. |
| iOS Simulator Debug build | PASS at `9e4602a4`, 23.270s, generic simulator target supporting iPhone and iPad. Compilation only; no simulator UI or physical-device acceptance. |
| Additional protected-transcript projections | Five products passed: 28,990 protected-tail, 139 registry, 211 voiced-admission, 3,302 streaming-state and 542 provisional-identity checks. Three completed at `ca1171c2`; two were rerun after the pure probe's pipeline-version projection repair in `1e87da9f`. |
| Independent source and architecture review | GO at exact `9e4602a4`, no P1/P2 findings. Prior integrated review at `62ec447a` and the test-only delta `09a60b40` also passed static review. These approvals do not replace runtime evidence. |

The emitted Release bundles retain `ai.pichi.voice`, version 1.6.12, build 34. Debug uses `ai.pichi.voice.debug`. All 13 Xcode application configuration blocks have unique identity settings. The String Catalog retains all existing entries in order, adds 112 keys, and has complete English/Russian entries for 3,222 keys, including 18 native plural entries.

### Failed attempts and corrections

- The initial portable run rejected an unregistered upstream recovery-copy runner. It was added to the existing registry. Package resolution used the existing lock file and task-owned checkouts. A separate accidental Python invocation of the shell check script was corrected; its error is retained as an invocation failure.
- Native compilation exposed renamed history operations, an obsolete sheet initializer and new capture events in existing test fixtures. Fixtures now use existing operations, reject unexpected diagnostic events and keep presentation-only echo events out of continuity counters.
- Mobile compilation/review found missing new pure dependencies and two pre-existing location files omitted by the generator. The shared manifest was corrected without changing desktop project bytes outside its generated mobile block. The unchanged PCM buffer synthesizer moved to the existing shared normalizer, and runtime capture event declarations moved into the existing capture contract. No second capture pipeline was added.
- Standalone failures came from stale source projections, a changed sheet payload and AppKit's separate shared field editor. The corrected harnesses use actual declarations and preserve the prior contrast, identity and cancellation thresholds. A real transcript-editor appearance regression was fixed by applying the existing shared app theme to that editor. The final probe checked 48 participant input states, 24 whole-sheet cases and 36 native root cases, including both the TextField and its actual editor.
- The first idle-session smoke test had two failures in a new fixture that relied on Foundation delivering task completion to a replacement async-session delegate. The fixture now observes real session invalidation and settled/gated session ownership. The focused rerun passed all four idle-lifetime tests. No production lifetime API or timeout was weakened.
- The first full native run at `62ec447a` was **3129 PASS, 20 FAIL, 80 SKIP**, exit 65, 318.853s, including three test-process crashes caused by continuing into indexes after failed count assertions. Those results remain retained and are not reclassified as passing.
- Baseline/current source-projection comparison proved that the stable-opening policy and protected transcript logic already existed in downstream `59e50790`. Legacy provisional-identity tests now explicitly select their intended policy; separate current-default assertions require unknown, weak and unlinked voices to remain unadmitted, with original native evidence unchanged. A real existing batch-continuity bug compared epoch-scoped tokens instead of their explicitly linked canonical identities. The fix changes only first-identity admission and never creates links. Differential controls showed one mapped token before, two after, one speaker in both, and one mapping throughout the unlinked negative control.
- Full native tests also exposed an existing Undo bug: text was restored but the prior optional privacy marker was not. The inverse now restores that marker with text, original text, edit state and revision. A new regression covers persisted `nil`, `false` and `true` states, while retaining redaction, failed/cancelled mutation and publication checks.
- Saved-application fixtures now explicitly request selected-application scope, matching both their intended test and the existing system-audio default. Overlay expectations preserve genuine model attribution and custom Russian labels. Rollback fixtures name archives for the configured repository and reject unrelated application archives.
- The new upstream long-dictation fixture abruptly cut a physical 15.05075s clip while its last word ended at 15.20s. The unchanged provider correctly rejected all timing evidence. Adding one second of real silence produced the same text/token/word counts with zero invalid timings. The native fixture retains nonempty timing requirements and now also checks every bound and exact timing equality across matcher settings. Production timing validation remains unchanged.

### Evidence and remaining gates

Logs, xcresults, source projections, initial failures, negative controls and hash manifests are retained in ignored local task artifacts. Standalone and remediation evidence also has independent SHA-256-verified copies. Test hosts were frozen separately from build products, signed with the existing valid development identity and verified with strict signatures and file/symlink manifests. The copied public CTranscribe framework needed a canonical versioned symlink layout before signing; its library bytes were unchanged. System permission stores were not reset. No private data, credentials, signer identities or local paths to private assets are committed.

The full native run exercises automatic synthetic/public fixtures. It does not establish microphone or Accessibility grants, real audio routes, cloud credentials, private Fluid Intelligence runtime behavior, default-model summary quality, or visual acceptance of the full app. Previously accepted summary semantic limitations remain limitations. The final xcresult retains 163 runtime warning records, including state changes during view updates and thread/QoS warnings; they are not silently suppressed.

At initial publication, mobile simulator UI, user review and subsequent physical-device checks were still pending. The acceptance follow-up below supersedes that initial status with the checks actually completed.

The initial update was published as a draft PR. The user subsequently requested completion of acceptance and a manual merge after passing checks, and separately requested delivery of the merged Release to the iPad. The existing macOS installation and active user capture remain protected throughout.

## PR #46 acceptance follow-up

The application candidate is `0d44a14be4acdce066e2938968b0eccd1e305d8b`. Native simulator acceptance exposed a pre-existing correction-picker bug: the visible `readableSpeakers` roster omitted known participants without readable fragments, preventing manual assignment to them. Desktop and mobile correction targets now use the existing `activeSpeakers` contract. Visible rosters keep their existing filtering; merged identities remain excluded and desktop excludes the current participant. Existing domain operations still own validation, persistence and atomic Undo.

The mobile test adapters now identify paragraph speaker captions through the actual native button and its exact label. Toggle actions preserve native row/control ownership and require hittability, a valid binary state and a state change; footer checks require full window containment. Correction-scope, word preservation, persistence and Undo assertions remain intact.

| Check | Actual result and provenance |
| --- | --- |
| Portable repository checks | Fresh PASS at `0d44a14b`, 22.812s, with only this acceptance report changed in the working tree. |
| macOS Debug build-for-testing | Fresh PASS at `0d44a14b`, 144.443s. |
| Normally signed macOS Debug build-for-testing | Fresh PASS at `0d44a14b`, 96.281s. The new frozen copy preserves all 19 Xcode effective entitlement keys, including Audio Input; strict signatures pass. |
| macOS Release arm64 | Fresh PASS at `0d44a14b`, 392.265s. |
| macOS Release x86_64 | Fresh PASS at `0d44a14b`, 394.492s. Physical Intel runtime remains unverified. |
| Mobile simulator build-for-testing | Fresh PASS at `0d44a14b`, 35.201s. |
| Signed iOS device Release build | Fresh PASS at `0d44a14b`. Compilation and signing only; not physical-device acceptance or the final merged-main delivery. |
| Targeted native corrections/recovery | Fresh PASS at `0d44a14b`: 201 passed, 0 failed, 2 skipped, 65.107s. No microphone capture. The saved-transcript presentation class belongs to the mobile target and is not claimed as part of this native result. |
| Real GigaAM and S1-mini | Four tests passed at compiled source `9e4602a4`, 20.660s: synthetic default chain, provider/files/API/meeting flow, bilingual cleanup and long Russian dictation. Reused for `0d44a14b` because inference, services, pinned model inputs, native model tests, resources and package pins are unchanged. These tests use synthetic speech, not the microphone. |
| Earlier full native suite | Retained result at `9e4602a4`: 3150 passed, 0 failed, 80 skipped. This is not a fresh full-suite result for `0d44a14b`; affected correction behavior has the fresh targeted result above. |
| macOS non-audio UI | Frozen source `9e4602a4` passed bounded English/Russian and light/dark settings, dictionary add/edit/delete including Ё/ё, wizard navigation/cancel, transcript edit/Undo, batch rename/Undo and SHA-verified Markdown export. The new frozen `0d44a14b` passed unused-participant menu visibility, current-speaker exclusion, reassignment, confirmed merge, both Undo operations and quit/reopen. All five original segment objects and speaker objects equal the committed synthetic fixture after Undo. |
| Mobile correction UI | Fresh PASS at `0d44a14b` on both simulators, 1 selector each with 0 failures/skips: iPhone 1621.39s, iPad 1300.61s. Both English/light and Russian/dark exercise whole-fragment and single-member changes, Undo, owner reassignment, actual restart/reopen and restoration through normal UI. Times include gated visual review and are not app latency measurements. |
| Mobile hosted presentation tests | Fresh PASS at `0d44a14b`: 46 passed, 0 failed/skipped, 6.123s across `MeetingLiveCaptionPresentationTests` and `MeetingSavedTranscriptPresentationTests`. The earlier separate five-class run remains 44 passed, 0 failed, 1 physical-only skip at its original pinned source. |
| Independent source and architecture review | GO at exact `0d44a14b`, no P1/P2 findings, including existing extension contracts, roster separation, correction ownership, merged/current identity exclusion and native UI assertions. A separate coordinating session independently reached the same static result. |

Passing mobile saved-session scopes also include privacy/orientation/footer navigation, Russian dark model settings, localized location settings, and address/history titles on both iPad and iPhone simulators. Their per-scope provenance and unchanged method-body/app-input proofs are retained; later production changes only affect the two correction target collections. All final correction and focused hosted jobs joined before subsequent checks. The user reviewed the actual native participant-picker frames for both form factors and explicitly accepted their appearance.

Earlier failed and interrupted attempts remain evidence. A first real-model launch was interrupted before any case ran; only the later four-test run establishes success. Initial mobile failures exposed native control/label assumptions and then the real missing correction target; none are reclassified as passing. An overlapping/orphaned simulator attempt is invalid acceptance evidence. Unexpected media found in an owned simulator was preserved with a complete independently hash-verified container copy, without listening, decoding or transcription. First-use or empty-cache loader behavior is not established by saved-session UI checks.

Permission preflight also exposed a local test-artifact preparation error. The first freezer rebuilt entitlements from `Fluid.entitlements` and lost Xcode's expanded Hardened Runtime capabilities. The project already enables Audio Input for Debug and Release, as does the downstream baseline. macOS explicitly denied the malformed frozen copy's microphone request before any system prompt. This is not evidence of a missing production capability. The repair follows the existing PR archive workflow: obtain Xcode's normally signed effective entitlements, preserve every key before framework normalization/re-signing, validate Audio Input and Hardened Runtime, then freeze a new copy for permission/audio checks. No private entitlement, permission-database reset or weaker signing policy is used.

The repaired frozen copy passed strict signatures with all 19 Xcode effective entitlement keys preserved. The normal microphone request was invoked. Manual OS permission approval remains pending because the computer-use controller rejects access to the protected system permission dialog for safety reasons. No alternate automation path is used to bypass that restriction.

Remaining acceptance gates are microphone/Accessibility delivery, meeting audio capture, active caption dragging and physical-device checks. The participant-picker simulator user review is complete. Live cloud requests and the unavailable proprietary Fluid Intelligence runtime remain unverified. Previously accepted summary semantic limitations remain unchanged. A minor dictionary playground confirmation label can remain stale after editing/deleting while the saved dictionary and drawer update correctly. Initial native runtime warnings and one targeted main-thread responsiveness warning are retained.

## Initial textual conflicts

Each path below was resolved by hunks, using the contract decisions above. Clean-merge semantic issues, including duplicated Xcode identity settings, updater trust and mobile membership, were reviewed separately.

| Path | Conflict and resolution |
| --- | --- |
| `Sources/Fluid/ContentView.swift` | Both sides extend navigation; retain upstream destinations and downstream localized shared navigation/theme. |
| `Sources/Fluid/Persistence/KeychainService.swift` | Upstream connection/credential work meets downstream request snapshots; retain authoritative keys, owned pools and joined cancellation. |
| `Sources/Fluid/Persistence/SettingsStore.swift` | Upstream settings additions meet extracted downstream preferences; remove duplicate declarations and preserve generic settings, locale and distribution contracts. |
| `Sources/Fluid/Services/AppServices+MeetingMenuBar.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Sources/Fluid/Services/AppServices.swift` | Upstream service/shortcut changes meet downstream route and capture ownership; retain immutable credentials, stop-target and generic resource boundaries. |
| `Sources/Fluid/Services/DictationPostProcessingService.swift` | Upstream service/shortcut changes meet downstream route and capture ownership; retain immutable credentials, stop-target and generic resource boundaries. |
| `Sources/Fluid/Services/FluidAudioProvider.swift` | New upstream dictionary operations meet downstream responsive/provider behavior; retain shared services, user data and immutable model admission. |
| `Sources/Fluid/Services/LLMClient.swift` | Upstream connection/credential work meets downstream request snapshots; retain authoritative keys, owned pools and joined cancellation. |
| `Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronBackend.swift` | Upstream meeting changes meet downstream retained/memory capture and native evidence; preserve resource/privacy gates, correction provenance and frozen processing pins. |
| `Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveTranscriptionCoordinator.swift` | Upstream meeting changes meet downstream retained/memory capture and native evidence; preserve resource/privacy gates, correction provenance and frozen processing pins. |
| `Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift` | Upstream meeting changes meet downstream retained/memory capture and native evidence; preserve resource/privacy gates, correction provenance and frozen processing pins. |
| `Sources/Fluid/Services/Meeting/MeetingModels.swift` | Upstream meeting changes meet downstream retained/memory capture and native evidence; preserve resource/privacy gates, correction provenance and frozen processing pins. |
| `Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift` | Upstream meeting changes meet downstream retained/memory capture and native evidence; preserve resource/privacy gates, correction provenance and frozen processing pins. |
| `Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift` | Upstream meeting changes meet downstream retained/memory capture and native evidence; preserve resource/privacy gates, correction provenance and frozen processing pins. |
| `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift` | Upstream meeting changes meet downstream retained/memory capture and native evidence; preserve resource/privacy gates, correction provenance and frozen processing pins. |
| `Sources/Fluid/Services/MenuBarManager.swift` | Upstream service/shortcut changes meet downstream route and capture ownership; retain immutable credentials, stop-target and generic resource boundaries. |
| `Sources/Fluid/Theme/Components/FluidGlassControls.swift` | New native controls meet shared/mobile appearance; use portable theme, genuine attribution and the existing platform boundary. |
| `Sources/Fluid/UI/AppNavigationState.swift` | Both sides extend navigation; retain upstream destinations and downstream localized shared navigation/theme. |
| `Sources/Fluid/UI/CustomDictionaryView.swift` | New upstream dictionary operations meet downstream responsive/provider behavior; retain shared services, user data and immutable model admission. |
| `Sources/Fluid/UI/DictionaryWordWizard.swift` | New upstream dictionary operations meet downstream responsive/provider behavior; retain shared services, user data and immutable model admission. |
| `Sources/Fluid/UI/MeetingAssignSpeakersSheet.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Sources/Fluid/UI/MeetingFloatingCaptionsPanel.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Sources/Fluid/UI/MeetingSessionCanvases.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Sources/Fluid/UI/MeetingTranscriptionView.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Sources/Fluid/UI/SettingsSearch.swift` | Upstream settings additions meet extracted downstream preferences; remove duplicate declarations and preserve generic settings, locale and distribution contracts. |
| `Sources/Fluid/UI/SettingsView.swift` | Upstream settings additions meet extracted downstream preferences; remove duplicate declarations and preserve generic settings, locale and distribution contracts. |
| `Sources/Fluid/Views/BottomOverlayView.swift` | New overlay presentation meets downstream routing/theme; presentation remains localized display data, never a credential or model admission source. |
| `Sources/Fluid/Views/BottomWaveformView.swift` | New overlay presentation meets downstream routing/theme; presentation remains localized display data, never a credential or model admission source. |
| `Tests/FluidDictationIntegrationTests/MeetingLiveReplayTests.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Tests/FluidDictationIntegrationTests/MeetingLiveTranscriptionTests.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Tests/FluidDictationIntegrationTests/MeetingParakeetNemotronBackendTests.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Tests/FluidDictationIntegrationTests/MeetingPhase4Tests.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Tests/FluidDictationIntegrationTests/MeetingRecoveryTests.swift` | Upstream meeting interaction/tests meet downstream IDs and lifecycle; reuse domain operations, preserve native evidence, explicit audio scope and complete Undo. |
| `Tests/FluidDictationIntegrationTests/SettingsNavigationStateTests.swift` | Upstream settings additions meet extracted downstream preferences; remove duplicate declarations and preserve generic settings, locale and distribution contracts. |
| `Tests/FluidDictationIntegrationTests/UpdatePromptIntegrationTests.swift` | Both sides extend navigation; retain upstream destinations and downstream localized shared navigation/theme. |
| `Tests/Standalone/DictionaryMatcherExperimentTests.swift` | New upstream dictionary operations meet downstream responsive/provider behavior; retain shared services, user data and immutable model admission. |
| `Tests/run_dictionary_matcher_experiment_tests.sh` | Both sides extend navigation; retain upstream destinations and downstream localized shared navigation/theme. |
| `.gitignore` | Both sides add local exclusions; retain downstream instructions/privacy and upstream Claude exclusions. |
| `Info.plist` | Both sides bump versions; use stable 1.6.12 with monotonically increasing downstream build 34. |
