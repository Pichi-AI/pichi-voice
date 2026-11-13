# FluidVoice stable 1.6.13 integration

Status: source integration and affected automated verification are complete for a qualified draft. A separate P2 limitation and manual acceptance remain open. This report does not authorize merging or publishing an application.

## Immutable inputs

| Input | Revision |
| --- | --- |
| Downstream baseline | `a866e344d6fc2fde140fe340bd9154846a45a57f` |
| Published upstream tag | `v1.6.13` |
| Exact upstream commit | `9912eca0d95f9d6ca6b99099d4434637563e19a1` |
| Common ancestor / prior beta 2 | `fc59c46315f2c26568e807b6bed1de5019e42c5b` |
| Task branch | `codex/upstream-sync-38cce9d6a1` |

The [official stable release](https://github.com/altic-dev/FluidVoice/releases/tag/v1.6.13) was published on November 13, 2026 at 11:25:26 UTC with a nonempty macOS DMG. The paginated release API returned 66 releases. Draft, Windows and independent runtime/artifact releases were excluded. Stable 1.6.12 and beta 2 are already ancestors of the baseline; the new stable commit is not. No newer published macOS beta was selected and no unpublished main commit is imported. Open PRs, origin sync branches, containing refs and pending merge metadata were checked before preparation; no duplicate containing this release SHA was found.

## Integration decisions

`prepare-upstream-sync.sh v1.6.13` created an isolated branch and a normal two-parent merge. Git initially reported 67 conflicted paths. The count describes this merge, not a measured frequency or cost of downstream divergence.

- Keep Pichi distribution identity, portable brand, Russian localization, provider connection/credential contracts and downstream release stamps. An automatic project-file merge silently appended upstream bundle IDs, product names and version keys. Remove those duplicate overrides; preserving only Info.plist would not preserve the application identity.
- Extend the existing extracted meeting/settings owners instead of restoring duplicate upstream properties. Preserve explicit source scope and narrow legacy behavior. Adopt upstream prompt-delay/custom-accent and command-model capabilities through those owners.
- Keep the existing admitted ASR/provider lease and start generation. Import the new correction carrier alongside pronunciation learning and replacement provenance. Freeze separate full-phrase archive permission and profile at capture admission; pronunciation consent alone never enables an utterance archive. No additional ASR pass is introduced for this carrier.
- Keep exact focus checks, partial-insertion handling, private-profile retirement and joined readers. Adopt upstream focused-editor search, transient AX read handling and clipboard-consumption evidence. A recovery notice offers copying and must not post a second paste.
- Preserve existing model selection. The new Qwen3 ASR 1.7B descriptor follows the existing universal inference provider; it does not revive the previously rejected 0.6B preview or silently select another model.

Meeting/history/API source integration is resolved. Final source review and measured verification are recorded below. The working application was not installed, replaced or re-signed by this task.

### Additional semantic resolutions

- Preserve raw native word IDs, timing, track and speaker evidence. Reuse the readable-turn projection for phrase replacements/quantities, projecting text changes back without collapsing native rows. Import completed cross-track reply barriers. Do not copy upstream blanket speaker inheritance into uncertain native evidence. Pipeline version 20 invalidates older final-processing caches because normalization and privacy publication semantics changed.
- Apply final dictionary/quantity formatting before the final privacy gate in PCM Stop and retained canonical processing. Keep original evidence protected separately. Add explicit regression cases for a synthetic dictionary replacement introducing a person name, and a quantity spanning two native word rows.
- Raw dictionary rules are attempt-local. Persist only their digest in the authenticated, unencrypted checkpoint header. A retained checkpoint requiring unavailable rules fails closed with an explicit restart rather than reading current rules. This limits automatic resume for such attempts and must not be presented as a fully transparent resume feature.
- Keep microphone-only in-person recordings and process-narrow legacy application selection. An optional saved all-instances field records only explicit app-wide picker consent. Source-only changes publish one notification after defaults and recency agree; the comparison includes audio scope and all-instances intent. Preserve ownership-aware rename and clear automatic-title fields through the existing serialized persistence queue.
- Import the session/ticket-bound monotonic end countdown and keep profile concealment, withdrawal, cancellation and joining. Existing call observation supplies evidence; a countdown cannot substitute for current eligibility.
- Keep profile-bound admitted FIFO history writes and metadata. Track imported/deleted IDs so a later legacy snapshot can import unseen rows without resurrecting cleared ones. Preserve ambiguous pre-accounting sources and defer cleanup until exact reconciliation or a verified recovery copy. Reading valid SQLite rows remains available.
- Full-phrase correction examples have separate default-off, profile-scoped consent. Queued/accepted archives share a 32-save/128 MiB admission bound. Accepted saves survive prompt dismissal, join through the existing profile owner and target the original profile. Validate pre-existing audio/metadata pairs before treating an example as saved. A rejected substitution cannot create a positive example.
- Live API reads the accepted coordinator projection in one main-actor snapshot without materializing an idle coordinator. Preserve profile checks before/after dispatch, route cancellation/joining, Host/Origin checks and configured-port validation. Live responses include no-store on errors and 304; transport headers also prevent caching of trust/parse rejections. Preserve the CLI guest-profile marker boundary while adopting upstream's optional sharing state. The helper entry point uses an optional-preserving conditional rather than treating unknown permission as Bool.
- Register nine new upstream leaf probes in the existing standalone runner, with their actual shell/Python interpreters. No new quarantine or skip is added. The initial registry error listed manual OTHER_PROBES as missing in its diagnostic even though those files exist; the real mismatch was the nine newly unregistered probes.
- A backup-refresh probe initially failed because its quick-start fixture selected an app while retaining the newly system-audio default mode. The real UI explicitly enters online-call mode before choosing that app. Updating the fixture to reproduce that action passed all 83 assertions; no production behavior patch was required for this failure.

### Verification checkpoints before freezing the candidate

These results bind to the described working source, not to a later final revision or runtime acceptance:

| Check | Result |
| --- | --- |
| Swift source syntax | 615 source files parsed successfully; not typechecking |
| Package resolution | Task-owned Xcode/SPM resolution passed |
| Paste policy | Focused-editor search, transient reads, field/clipboard evidence, deferred recovery passed |
| Private pasteboards | 18 cases passed; no real keyboard events or system clipboard used |
| Command cancellation | 255 checks passed with actual production agent loop/streaming and in-memory store; standalone compiler warnings remain |
| Backup/source refresh | 83 production-handler assertions passed after the fixture correction |
| Release highlights | Lifecycle/version ledger and complete English/Russian shipped content passed; unavailable upstream private cleanup offerings are excluded |
| Distribution identity | 9 identity and 3 build-setting tests passed; 13 settings blocks have unique keys |
| Shared source membership | Mobile target and native SDK checksum/provenance/license checks passed |
| Initial compilation | Failed in bundled helper because upstream changed sharing permission to Bool?; caller corrected, combined build running |
| Initial portable check | Failed on nine newly unregistered upstream probes; registry corrected, repeat running |

These early checkpoints are superseded only in the scopes explicitly covered by the following final results.

## Initial conflict inventory

Every initial conflicted path is listed for traceability. Resolution and validation must be assessed on the combined candidate, not on independent worker syntax checks.

- `Info.plist`
- `Sources/Fluid/ContentView.swift`
- `Sources/Fluid/Persistence/BackupService.swift`
- `Sources/Fluid/Persistence/SettingsStore+CommandMode.swift`
- `Sources/Fluid/Persistence/SettingsStore.swift`
- `Sources/Fluid/Persistence/TranscriptionHistoryDatabase.swift`
- `Sources/Fluid/Persistence/TranscriptionHistoryStore.swift`
- `Sources/Fluid/Services/ASRService.swift`
- `Sources/Fluid/Services/AppServices+MeetingMenuBar.swift`
- `Sources/Fluid/Services/AutomaticDictionaryCorrectionTracker.swift`
- `Sources/Fluid/Services/AutomaticDictionaryTrainingSession.swift`
- `Sources/Fluid/Services/CommandModeService.swift`
- `Sources/Fluid/Services/DictationOverlayPresentation.swift`
- `Sources/Fluid/Services/FluidAudioProvider.swift`
- `Sources/Fluid/Services/FluidServe/FluidServeCommand.swift`
- `Sources/Fluid/Services/FluidServe/FluidServeMeetings.swift`
- `Sources/Fluid/Services/FluidServe/FluidServeSelfCheck.swift`
- `Sources/Fluid/Services/FluidServe/FluidServeSkill.swift`
- `Sources/Fluid/Services/LocalAPI/LocalAPIRouter.swift`
- `Sources/Fluid/Services/LocalAPI/LocalAPIServer.swift`
- `Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronBackend.swift`
- `Sources/Fluid/Services/Meeting/MeetingAutoDetector.swift`
- `Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift`
- `Sources/Fluid/Services/Meeting/MeetingModels.swift`
- `Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift`
- `Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift`
- `Sources/Fluid/Services/Meeting/MeetingRecordingSource.swift`
- `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift`
- `Sources/Fluid/Services/Meeting/MeetingSessionStore.swift`
- `Sources/Fluid/Services/MenuBarManager.swift`
- `Sources/Fluid/Services/PasteDeliveryCoordinator.swift`
- `Sources/Fluid/Services/PasteVerifier.swift`
- `Sources/Fluid/Services/PrivateAIProvider.swift`
- `Sources/Fluid/Services/TypingService.swift`
- `Sources/Fluid/Theme/Components/EditableTitle.swift`
- `Sources/Fluid/UI/AISettings/DictationScreenContextSettings.swift`
- `Sources/Fluid/UI/AISettings/PrivateAIModelPresentation.swift`
- `Sources/Fluid/UI/AISettings/PrivateAISettingsController.swift`
- `Sources/Fluid/UI/CustomDictionaryView.swift`
- `Sources/Fluid/UI/DashboardView.swift`
- `Sources/Fluid/UI/MeetingDetectionPrompt.swift`
- `Sources/Fluid/UI/MeetingRecordingSettingsSheet.swift`
- `Sources/Fluid/UI/MeetingRecordingSourcePrompt.swift`
- `Sources/Fluid/UI/MeetingSessionCanvases.swift`
- `Sources/Fluid/UI/MeetingTranscriptionView.swift`
- `Sources/Fluid/UI/ReleaseFeaturePreview.swift`
- `Sources/Fluid/UI/ReleaseHighlightsContent.swift`
- `Sources/Fluid/UI/SettingsView.swift`
- `Sources/Fluid/Views/AutomaticDictionaryCorrectionOverlay.swift`
- `Sources/Fluid/Views/BottomOverlayView.swift`
- `Tests/CommandModelCatalogTests.swift`
- `Tests/FluidDictationIntegrationTests/FluidServeTests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingAEC3Tests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingAPIControllerTests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingOverlayModelsTests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingParakeetNemotronBackendTests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingPhase4Tests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingProcessingConfigurationTests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingProviderOptionsTests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingRecordingSourceTests.swift`
- `Tests/FluidDictationIntegrationTests/MeetingRecoveryTests.swift`
- `Tests/FluidDictationIntegrationTests/ParakeetSpeechModelCatalogTests.swift`
- `Tests/FluidDictationIntegrationTests/PrivateAIProviderPromptFormatTests.swift`
- `Tests/HistoryPersistenceBoundaryTests.swift`
- `Tests/PasteReadReceiptReproductionTests.swift`
- `Tests/run_command_cancellation_tests.sh`
- `Tests/run_meeting_backup_refresh_tests.py`


## Open privacy/normalization limitation

Independent review identified a P2 parity gap that remains open: PCM final normalization receives already-protected capture text, so a saved rule cannot match a trigger that privacy already masked. Retained canonical processing can apply that rule before final redaction. A second focused architecture review confirmed no existing complete raw transcript can supply that trigger: the bounded privacy tail and streaming state deliberately discard it. Retaining unprotected full text or replaying healthy ASR would change the accepted privacy/resource/Stop contracts. Neither workaround is introduced in this sync.

The source keeps protected-text normalization and the final redaction pass, discloses the limitation with the dictionary controls, and adds a caller-level synthetic PCM finalization test with privacy-on/off controls and no-additional-ASR assertions. This records the limitation; it does not establish sensitive-trigger parity or close the review finding. The draft must not be described as fully accepted or merge-ready. A future fix needs a concrete, bounded existing-boundary design that preserves protected checkpoints, native evidence and joined healthy Stop. The user has not accepted this tradeoff as a permanent product decision.


## Final source and regression results

| Revision | Meaning |
| --- | --- |
| `f4163199aa8a5557ce923ea3cac5d06d56c18a1f` | Normal upstream merge, exact parents a866 and 9912 |
| `243e810473c064e05f8e1a0a6455e8e990950804` | Full native/standalone and final mobile candidate |
| `2f1ac1b6` | Composer readiness and remaining native fixture corrections |
| `29f4daa324889c0c4b68eeff3b4eadad357e574f` | Final reviewed production source and final transport assertion |

After the final reviewed production source, cebff2ab3 and 040f122c5 change only the VAD source-isolation fixture. The final publication adds this report; production inputs are identical to 29f4daa3. Every result retains its own revision; no new full native aggregate is inferred by adding successful reruns to an earlier run.

| Check | Actual result and scope |
| --- | --- |
| Portable repository checks | PASS on final source. Configuration, syntax, catalogs, native SDK provenance, mobile membership, identity, policy and upstream-sync controls passed. |
| Changed-line SwiftLint | PASS, zero blocking findings and zero notes in the final production delta. |
| macOS Debug/test build | PASS on the immutable native candidates, unsigned and isolated as `ai.pichi.voice.regression.debug`. |
| macOS Release | PASS on 29f4daa3, unsigned, separate DerivedData; stamped build verification records `AppSourceRevision=29f4daa324889c0c4b68eeff3b4eadad357e574f` in the built plist and the local receipt. No install, DMG or app release was performed. |
| Distribution settings | Pichi display names and namespaces retained. Both configurations preserve downstream 0.2.0/build 73 rather than upstream 1.6.13/build 34. Ordinary local regression builds leave the optional source-stamp setting `unknown`; their immutable source and binary hashes are recorded externally, not represented as signed distribution proof. |
| Initial full native at 1fa17560 | 4,066 total: 3,930 passed, 52 failed, 84 skipped. An inherited shared-termination leak accounts for the later admission failure group; other failures identified stale fixture contracts and integration defects. |
| Full native at 243e8104 | 4,066 total: 3,976 passed, six failed, 84 skipped. Remaining failures were two saved-default expectations, two CAF fixture creation errors, missing test-host menu binding, and an asynchronous URLProtocol cancellation observation. |
| Affected native at 2f1ac1b6 | 68 total: 66 passed, zero failed, two existing skips. Covers all six former failing cases: saved-default matrices, real synthetic retained CAF bytes, caption-window stability and transport cancellation. Composer/readiness is independently covered by the admission fixture. |
| Final updater case at clean 29f4daa3 | One passed, zero failed. Keeps the stop-callback assertion and additionally observes that the injected URLSession has no active task after cancellation. No added sleep, changed deadline or downloader rewrite. |
| Shared-state isolation control at e7e9c311 | 142 total: 138 passed, zero failed, four existing skips. The GigaAM fixture terminates only its injected owner, then ordinary shared admission succeeds; the later model/deletion/token-budget classes pass in the same test process. |
| Standalone at 243e8104 | 123/123 selected leaf probes PASS. Final-source 29f4daa3 repeated 123 leaves: 122 passed and one asynchronous VAD fixture failed. The VAD completion predicate and acknowledgement now wait for the complete measured interval, preserving thresholds and existing bounded timeouts. Three isolated repeats passed, followed by a four-probe concurrent-load check at 040f122c5: four passed, zero failed. No new full aggregate is claimed after this test-only correction. The existing opt-in/quarantine selection remains explicit. |
| Composer-to-service alias regression | 477 admission checks passed after the readiness correction, with actual composer predicate and service admission, cache-only production credential/storage operations and intercepted HTTP. No unexpected URL or interactive credential request is permitted. |
| iOS simulator build/test build at 243e8104 | PASS on Xcode 27.2 with iOS 27.0 simulator runtime. Shared normalization/archive dependencies are in the versioned mobile manifest. |
| Mobile hosted integration at 243e8104 | 449 total: 401 passed, zero failed, 48 existing skips. The installation-failure test explicitly selects strict memory-only admission; retained recording still preserves its existing speech-failure isolation. |
| Native simulator UI at 243e8104 | iPhone 18 Pro and iPad Pro 13-inch M5 settings/model flow PASS in Russian light/dark themes. No model was installed or prepared, and no recording, sync publication or physical-device acceptance was attempted. |
| Native simulator frames | Final iPhone: 48 saved frames, 24 unique states, one missed scheduled second. Final iPad: 33 frames, 25 unique states, two missed seconds. Zero capture errors. All unique states were inspected, with full-size model frames checked for copy/layout. This is incomplete one-second coverage and is not a latency/FPS measurement. Earlier frames and their distinct provenance remain preserved. |
| Mobile evidence reuse | Every mobile production input, resource and project membership is unchanged from 243e8104 through the final source delta; the later production change is the macOS-only Command Mode settings extension. This equivalence is retained in the local receipt. |
| Independent review | Initial combined f4163199 review found material issues. Corrected deltas were independently reviewed through 1fa17560, 243e8104 and exact 29f4daa3. Final review reports no new P1/P2 and closes the alias/UI and saved-default-matrix findings at source. It explicitly retains the separate masked-private-PCM P2 and does not declare merge readiness. |

### Additional resolutions discovered by complete checking

- The new universal Command Mode presentation preflight initially rejected a valid custom provider alias before authoritative configuration resolution. Apple availability admission remains in its own branch. Remote readiness and inference now share `verifiedChatModelConfiguration`, retaining exact registered-ID credential/options precedence, eligible model checks and stale/unknown rejection. The real composer predicate is exercised before the actual service call; a stale-options control disables the composer.
- A saved legacy compatibility default migrates to the production backend for all tested languages. Registered model selection takes precedence. Explicit legacy and unknown request overrides remain pinned and reject unsupported execution; settings are not silently rewritten.
- The default unselected composite model is upstream Pro. Explicit compatible English V2 selection and existing recording/model/artifact pins remain valid. Tests that mean V2 pin V2 rather than borrowing a mutable generic default.
- The GigaAM reuse fixture used the real shared residency coordinator, then called termination cleanup. Its file, coordinator and causal shutdown method are identical in the starting baseline. The fix injects the existing owned coordinator and retains joined shutdown; no production reset or new quarantine is used.
- Complete checks exposed obsolete standalone witnesses inherited from PR175: preview reuse, GigaAM execution-provider/work types and asynchronous admitted cleanup. Input-hash comparisons distinguish those unchanged baseline mismatches from new upstream contract additions. Probes now compile actual value/metadata declarations with inert runtime/IO boundaries.
- The helper icon lookup failed inside a worker sandbox while Finder existed. The parent performed representative native preflights and the actual unrestricted picker passed 86 checks. No application lookup workaround was added.
- Generic removal of the `Fluid-1 ` prefix corrupted genuine model attribution and user model labels. The model-name callback now remains verbatim, with short presentation labels kept separate. The iPad visual review also found the shared Pro card incorrectly saying Mac; shared copy now says device in English and Russian.
- Two existing opt-in real-model/replay test identifiers were missing from the skip ledger. They are documented with their existing guards, layers and privacy prerequisites. No new `XCTSkip`, quarantine, timing relaxation, real-model permission or private input was added. `Tests/quarantine.json` is unchanged.
- A late VAD source-isolation fixture equated the latest non-speech state with scored coverage of the complete requested interval. Under concurrent compilation, that could end its wait before coverage reached the required endpoint. Its existing bounded loop now checks that coverage and the existing bounded acknowledgement supplies the final proof. The production detector and silence thresholds are unchanged; repeated runs are one fixture finding, not new incidents.

### Limits and next acceptance

The masked-trigger PCM P2 described above remains open and has not been accepted as a permanent product decision. It must remain visible in the draft. Also outstanding are exact signed macOS microphone/system-audio/caption/hotkey/editor acceptance, actual model quality/download/runtime checks, Apple Intelligence runtime availability, and physical iPhone/iPad acceptance after the simulator images are reviewed. Earlier beta hardware proofs retain their original revisions and are not relabeled as stable 1.6.13 acceptance. The public upstream source does not supply the private Fluid Intelligence runtime.

All application/source changes are in the task branch. No main merge, app installation, updater publication, credential change or upstream push was performed. Use a normal merge commit if this draft is later accepted; squashing or rebasing would discard upstream ancestry used by future release deduplication.

## Knowledge and resource preservation

The existing personal Spaces integration journal contains dated source-level findings, validation limits and the unresolved PCM issue. Repeated compilation/CI attempts are linked to their original cause rather than counted as new incidents. A successful fixture correction is not presented as a new production fix or as evidence of real-model quality.

Workers used isolated branches/worktrees. Completed implementation/probe worktrees were removed after exact content integration and hash-verified copies of required ignored evidence. Both owned UI simulators were shut down and deleted after inspecting and independently preserving their small synthetic app containers; the runner-created hosted simulator was also deleted. All screenshots and xcresults remain in local private artifacts, outside version control. The user's installed application, original recordings, model caches, other sessions and physical devices were preserved.
