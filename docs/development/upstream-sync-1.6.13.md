# FluidVoice stable 1.6.13 integration

Status: source integration resolved; combined verification and independent review in progress. This report does not authorize merging or publishing an application.

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

Meeting/history/API source integration is resolved. Combined regression, final review and publication results are pending. The working application is not installed, replaced or re-signed by this task.

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

Final portable/native/mobile results, exact reviewed revision, remaining limitations and draft PR will be appended after combined verification.

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
