# Native account isolation and protected publication

Status: N2 inventory and interface proposal. Runtime integration is waiting for the coordinator-approved frozen N1 account implementation and W2 transport fixture. This document does not enable sign-in or cloud publication.

Inputs: native baseline `59e5079066406ff2f2ecdec8c1c2395eaf69e052`, delivery plan and contract v1 at `85943ce799bc287097004f72feea7e318d443b97`. Contract changes must go through the coordinator. Source references below describe the native baseline.

## Existing meeting boundary

`MeetingSessionStoring` already covers create/save/load/history/recovery, directory resolution and deletion. Extend this boundary instead of introducing another meeting pipeline. `MeetingSessionStore(rootDirectory:)` provides the existing filesystem injection seam.

The current default root is Application Support / `AppBrand.storageNamespace` / `Meetings`. Preserve this legacy root as the guest profile. Keeping its files in place avoids an unnecessary destructive copy migration. A versioned atomic profile registry must identify it as guest, without attributing it to the first account that signs in. New account roots must use an opaque deterministic identity key derived from the trusted distribution plus N1's verified issuer, subject and internal user ID. Do not derive paths from raw remote identifiers or email.

The active profile and the owner of an admitted recording are different lifetimes. All reads must authorize the visible profile; every capture/checkpoint/terminal write must remain bound to the owner fixed at admission. A switchable global root by itself can retarget an old save into the next profile. The existing `MeetingSessionPersistenceQueue` is asynchronous and coalesces per-session saves, so it also needs the immutable owner binding.

### All direct shared store references

There are 15 direct `MeetingSessionStore.shared` references in eight production files at the baseline:

| Source | Access | Required boundary |
| --- | --- | --- |
| `Sources/Mobile/MobileApp.swift:67` | Mobile composition default | N1-owned composition, modify only after handoff |
| `Sources/Fluid/Services/AppServices.swift:210` | Desktop coordinator composition | N1-owned composition, modify only after handoff |
| `Sources/Fluid/UI/MeetingHistorySnapshot.swift:15` | Default history loader | Inject active-profile store; invalidate and join old loads on switch |
| `Sources/Fluid/Services/LocalAPI/LocalAPIRouter.swift:11` | Default Local API store | Use the same authorized profile boundary |
| `Sources/Fluid/Services/Meeting/MeetingSegmentPlayback.swift:51` | Load canonical session | Profile-bound load and generation check |
| `Sources/Fluid/Services/Meeting/MeetingSegmentPlayback.swift:52` | Resolve audio directory | Same owner as loaded session; stop old playback on switch |
| `Sources/Fluid/Services/Meeting/MeetingSummaryController.swift:182` | Read manual summary cache | Profile-bound directory and source |
| `Sources/Fluid/Services/Meeting/MeetingSummaryController.swift:275` | Save remote manual summary | Immutable owner and joined cancellation |
| `Sources/Fluid/Services/Meeting/MeetingSummaryController.swift:347` | Save on-device manual summary | Immutable owner and joined cancellation |
| `Sources/Fluid/Services/Meeting/PichiMeetingSummaryController.swift:230` | Read structured summary cache | Profile-bound directory and source |
| `Sources/Fluid/Services/Meeting/PichiMeetingSummaryController.swift:286` | Save structured summary cache | Immutable owner and joined cancellation |
| `Sources/Fluid/UI/MeetingTranscriptionView.swift:1101` | Reload before transcript export | Active-profile authorization |
| `Sources/Fluid/UI/MeetingTranscriptionView.swift:1111` | Resolve audio export directory | Same authorized owner |
| `Sources/Fluid/UI/MeetingTranscriptionView.swift:1141` | Reload before audio export | Active-profile authorization |
| `Sources/Fluid/UI/MeetingTranscriptionView.swift:1151` | Resolve export source directory | Same authorized owner |

### Indirect and retained reads

| Source | Existing behavior | Required switch behavior |
| --- | --- | --- |
| `Sources/Fluid/ContentView.swift:258` | Window retains `MeetingHistorySnapshot` | Clear sessions, selection, search, drafts and derived transcript projections before presenting another profile |
| `Sources/Mobile/MobileMeetingRoot.swift:61` | Injected history load closure | Bind closure and retained history to the active generation |
| `Sources/Mobile/MobileMeetingRoot.swift:880` | Transcript export reloads from injected store | Recheck generation after await, before staging/sharing |
| `Sources/Mobile/MobileMeetingRoot.swift:894` | Audio export reload and directory lookup | Recheck profile and generation; discard pending share payload |
| `Sources/Mobile/MobileMeetingRoot.swift:903` | Protected export reloads from injected store | Recheck profile and generation; discard pending share payload |
| `Sources/Fluid/Services/LocalAPI/MeetingAPIController.swift:47` | List through injected store | Return only current profile; no stale completion after switch |
| `Sources/Fluid/Services/LocalAPI/MeetingAPIController.swift:79` | Transcript lookup through injected store | Foreign UUID must return unavailable, with no directory escape |
| `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift:759` | Persist capture admission | Freeze profile, verified account/workspace and consent before this create |
| `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift:2522` | Persist completed source | Reload the durable snapshot before considering publication |
| `Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift:1894` | Recovery load | Discover only the current profile; preserve former account's unfinished recording |
| `Sources/Fluid/Services/Meeting/MeetingSessionPersistenceQueue.swift:29` | Background snapshot save | Never resolve ownership using current selection at dequeue time |
| `Sources/Fluid/Services/AppServices.swift:155` | Retains active summary controllers | Cancel and join former-profile summaries; remove retained source/document projections |
| `Sources/FVServe/main.swift:35` | Standalone helper directly resolves legacy root, global sharing consent and custom prompt | Use an authorized profile boundary or fail closed in account mode; this path bypasses the application store injection |

Auth failure and logout must not stop local capture or erase meetings. If recording remains active across logout, it continues writing only to its frozen profile. Its transcript and controls must not be exposed as the next account's recording. Presentation needs an explicit policy/handoff from N1/N3/N4; clearing the storage list alone is insufficient.

## Private profile inventory

The profile inventory includes raw text, prompts, audio evidence, credentials and derived indexes. Do not clone device settings into an account profile or treat these private values as device-wide by accident.

| Area and source | Current path/key or retained state | Required boundary |
| --- | --- | --- |
| `Sources/Fluid/Services/Meeting/Backend/MeetingOwnerVoiceProfile.swift:207` | `<namespace>/OwnerVoice/profile.json`; injectable `fileURL` | One private profile root; leave original guest file intact |
| `Sources/Fluid/Services/Meeting/Backend/MeetingOwnerVoiceProfile.swift:285` | Shared service, immutable store, enrollment draft revision | Profile-bound service and account-generation rejection of stale drafts |
| `Sources/Fluid/Services/Meeting/Backend/MeetingProductionParakeetNemotronRuntime.swift:539` | Direct default OwnerVoice store load | Freeze the profile snapshot at existing attempt admission; never load the next account's voice |
| `Sources/Fluid/UI/MeetingOwnerVoiceSettings.swift:124` | Injected service defaults to shared; retained draft/task | Inject profile service, join enrollment and clear draft on switch |
| `Sources/Fluid/Persistence/SettingsStoreMeetingPreferences.swift:326` | `CustomDictionaryEntries` JSON Data | Profile-scoped defaults and immutable admission snapshot |
| `Sources/Fluid/Persistence/SettingsStore+SensitiveDataDictionary.swift:7` | `SensitiveDataDictionaryEntries` | Preserve throwing read and frozen redactor; no new profile lookup within an admitted attempt |
| `Sources/Fluid/Services/PronunciationDictionaryStore.swift:62` | `<namespace>/pronunciation-dictionary-v1.json`; actor document/revisions | Use existing fileURL injection with an entire profile-specific parent directory |
| `Sources/Fluid/Services/PronunciationDictionaryStore.swift:244` | Sibling `pronunciation-inspection/<UUID>.plist` | Profile-specific parent prevents cross-profile cleanup |
| `Sources/Fluid/Services/PronunciationDictionaryStore.swift:451` | Sibling `pronunciation-audio/<UUID>.json`, includes PCM | Private audio remains local; isolate load/orphan cleanup at lines 474-507 |
| `Sources/Fluid/Services/ParakeetVocabularyStore.swift:87` | `<namespace>/parakeet_custom_vocabulary.json`; private singleton initializer | Add root injection and profile-specific retained vocabulary |
| `Sources/Fluid/Services/ParakeetVocabularyStore.swift:152` | Static `readSearchTerms()` directly reads default path | Search must use the same authorized vocabulary root |
| `Sources/Fluid/Persistence/SettingsStore.swift:17` | Shared store accepts defaults; provider/dictionary/prompt caches | Separate private preferences from an explicit device-setting allowlist |
| `Sources/Fluid/Persistence/SettingsStoreKeys.swift:184` | `DictationPromptProfiles`, `AppPromptBindings`, `CustomDictationPrompt`, prompt overrides, `SavedProviders` | Private profile scope; imported prompts and destinations cannot become another account's defaults |
| `Sources/Fluid/Persistence/SettingsStore.swift:44` | Fixed `KeychainService.shared` despite injected defaults | Defaults injection alone cannot isolate provider credentials |
| `Sources/Fluid/Persistence/KeychainService.swift:55` | Cached provider-key aggregate under `<bundle>.provider-api-keys` / `providerApiKeys` | Separate N1 auth credentials; keep existing provider keys guest-private unless explicit device-wide policy is approved |
| `Sources/Fluid/Persistence/SettingsStore+PromptRouting.swift:14` | Direct `.standard` reads/writes | Route through the selected profile's injected defaults |
| `Sources/Fluid/Persistence/SettingsStore+CommandMode.swift:10` | Direct `.standard` reads/writes | Same profile boundary |
| `Sources/Fluid/Services/ASRService.swift:7703` | Static compiled private dictionary patterns | Invalidate cached patterns at profile change using the existing invalidation hook at line 7777 |
| `Sources/Fluid/Services/DictionaryAudioLearningService.swift:12` | Queued private text/PCM; cancellation can retry at lines 110-120 | Joined profile cancellation must not requeue a former account's learning work |
| `Sources/Fluid/Services/DictionaryNegativeExamples.swift:62` | `<namespace>/dictionary-negative-examples-v1.plist`; acoustic frame features read by matcher | Reuse existing URL injection with a private profile root, preserve legacy guest data and invalidate admitted correction generations |
| `Sources/Fluid/Services/AutomaticDictionaryCorrectionTracker.swift:25` | Heard/corrected text in `AutomaticDictionarySuggestionPolicyStateV1`, plus retained observation/evidence tasks at lines 192-195 | Reuse defaults injection, cancel and join old observations/training before showing another profile |
| `Sources/Fluid/Services/DictionaryPronunciationExperiment.swift:68` | Optional `DictionaryDebug` archive contains PCM, transcripts, profiles and inspection/training evidence | Reuse directory injection with private profile root; preserve existing guest archive; never let profile cleanup trim another profile's evidence |
| `Sources/Fluid/Services/DictionaryTransferService.swift:240` | Export/restore uses shared settings/vocabulary | Pin source/target profile across the complete operation |
| `Sources/Fluid/Persistence/BackupService.swift:216` | Shared settings/prompts/pronunciation/dictation-history export | Pin source profile and validate generation after actor hops |
| `Sources/Fluid/Persistence/BackupService.swift:261` | Multi-stage restore into shared stores | Pin restore target; never continue into the next account |
| `Sources/Fluid/Persistence/TranscriptionHistoryDatabase.swift:135` | `<namespace>/TranscriptionHistory.sqlite3`, legacy `TranscriptionHistoryEntries` migration | Use existing writer injection, retain guest migration inputs until verified |
| `Sources/Fluid/Persistence/TranscriptionHistoryStore.swift:255` | Entries, pending writes, summaries, selection/audio-budget tasks | Join work and recreate projections; keep admitted writer ownership |
| `Sources/Fluid/Persistence/DictationAudioHistoryStore.swift:45` | `<namespace>/DictationAudioHistory`, singleton root | Add root injection; playback/export/deletion use the same profile |
| `Sources/Fluid/Persistence/ChatHistoryStore.swift:131` | `CommandModeChatSessions`, `CommandModeCurrentChatID` | Existing defaults injection plus atomic replacement of visible messages/selection |
| `Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift:161` | `FileTranscriptionHistoryEntries` | Existing defaults injection plus visible selection reset |
| `Sources/Fluid/Persistence/Zeppelin/FluidZeppelinRoot.swift:17` | `<namespace>/zeppelin`, cached open handles | Private derived index root and joined close at line 77 |
| `Sources/Fluid/Persistence/Search/SearchIndexCoordinator.swift:105` | Subscriptions to global chat/file stores | Inject matching profile sources; existing joined `stop()` at line 185 |
| `Sources/Fluid/Services/AppSearch/AppSearchService.swift:288` | Global history/settings/vocabulary reads, visible results | Rebind all sources together and clear old results via `stop()` at line 149 |
| `Sources/Fluid/Services/LocalAPI/HistoryAPIController.swift:34` | Shared raw/processed text and app/window metadata | Freeze authorized request profile; reject stale awaited completion |
| `Sources/Fluid/Services/LocalAPI/DictionaryAPIController.swift:125` | Shared replacement dictionary; custom vocabulary at line 166 | Profile-specific reads/writes with the same request boundary |

No dedicated reversible PII recovery-map store was found. `Sources/Fluid/Services/Privacy/PichiTranscriptPrivacyService.swift:115` explicitly defines results without recovery maps. Public model artifacts remain under their existing shared resource ownership; they are not copied or deleted on account switch.

Existing injection points cover most filesystem/defaults stores. Extend the missing constructors and direct bypasses only where necessary. A second hierarchy of profile-specific inference engines, resource stores or pipelines is unnecessary.

## Shared sync/status proposal for N3 and N4

The concrete Swift API will bind the approved N1 identity/context/generation types rather than defining a duplicate account model. Proposed single shared service: `PichiCloudPublicationService`, observable on the main actor, with durable work on an actor. Platform views consume a sanitized snapshot and never receive credentials.

| Member | Proposed operation and semantics |
| --- | --- |
| `snapshot` | Current profile/workspace consent, pause reason and per-record statuses; no other account's rows |
| `setAutomaticPublicationEnabled(_:) async throws` | Changes only the selected verified account/workspace, default false; affects future admissions only |
| `status(for:)` | Returns current-profile record status plus an eligibility/withholding reason |
| `send(_:) async throws` | Admits only an already eligible owner-bound record; never claims guest history or grants historical consent |
| `retry(_:) async throws` | Reuses exact stored operation UUID, revision, assessment binding and payload bytes |
| `pause() async` | Stop admission, cancel and join active transfer, retain durable items |
| `resume() async throws` | Resume only current verified owner/workspace after capability and configuration checks |
| `reconcile(_:) async throws` | Query the owner-authorized receipt and update analysis separately from upload acceptance |
| `resolveAssessment(_:participantID:criteriaIDs:) async throws` | Use W2's authorized pending-assessment operation; never infer represented employee from a voice label |
| N1 joined logout hook | Pause owner queue, join transfer and clear in-memory projection before the next account is visible |

The exact type names and hook signature are pending N1's frozen API. This is an interface proposal, not a production stub or a contract change. W2 must supply the authorized criteria/binding discovery or destination path before native assessment resolution is presented as usable.

Proposed record statuses distinguish `localOnly`, `withheld(reason)`, `queued`, `sending`, `retryScheduled`, `paused(reason)`, `accepted(receipt)` and `conflict`. Analysis remains a separate value with v1's `queued`, `running`, `succeeded`, `failed`, `needsParticipant` and `needsCriteria`. User copy belongs to N3's shared String Catalog entries. Store stable reason codes instead of localized strings.

## Durable admission and delivery state machine

1. Capture admission snapshots N1's verified owner, organization/workspace, local profile, current generation and per-scope consent. Missing trusted configuration or consent means local-only. Existing guest records remain guest forever unless a future explicit migration flow is authorized.
2. After terminal persistence, reload by the frozen owner. Require persisted completion, protected capture policy, no original-text fields, verified complete coverage and no excluded transcript intervals. Unknown completeness is withheld from automatic analysis. Use `MeetingTranscriptExporter.protectedTranscriptJSON`, with its 750,000-byte and 100,000-UTF-16-unit limits and existing allowlist. Never fall back to internal JSON or audio.
3. Freeze one operation UUID, source revision 1, exact UTF-8 protected bytes, SHA-256, destination and explicit assessment binding before network admission. Persist payload and envelope atomically in the profile outbox with private file permissions. Reopening an item must verify its digest and owner before any transport.
4. A later edit, consent toggle, workspace selection or login cannot mutate queued bytes or destination. Do not silently enqueue a second source for the same local admission. Cloud deletion and post-publication edits remain separate policies.
5. Send through N1's owner/generation-bound authorized operation. Persist acceptance receipt before presenting acceptance. A lost response returns to a durable retry of identical bytes/key; the server's persistent deduplication is authoritative. Do not claim client retries alone prove absence of duplicate billing.
6. Keep accepted upload and analysis outcome separate. Reconcile receipt status under the same owner. Retain pending participant/criteria status until an explicitly authorized choice resolves it.
7. Network, eligible 429 and 5xx errors receive bounded retry/backoff and bounded `Retry-After`. 401 pauses for reauthentication; 403 pauses for permission review; 409 becomes an explicit source conflict; validation and size failures remain local and do not retry indefinitely. Logout joins active work and preserves it paused for its original owner.

## Required dependency handoffs

- N1 frozen commit and concrete verified identity/context/generation types; selected-workspace observation; owner-bound API credential operation; joined pre-switch/logout hooks; a safe admission snapshot that cannot change across an await; composition/Xcode ownership release.
- W2 frozen fixture/base and exact request/receipt/error codes for POST imports, GET status and PATCH assessment; accepted-but-response-lost fixture; approved local test endpoint/credential ownership if live integration is admitted.
- N3/N4 lifecycle policy for hiding former-profile active capture and clearing view-local selections, drafts, share files and summary projections without terminating recording.
- Coordinator review of this interface proposal before dependent UI binds to it.
- Coordinator classification of inference provider credentials and user-authored model/API configuration. The safe proposed default is guest-private legacy values plus empty account-private namespaces, with no automatic copy into the first signed-in account. Public model files and explicitly allowlisted device preferences remain shared.

## Verification plan and current evidence

Use the existing production-code standalone probes and native integration targets, with synthetic transcript fixtures. No model download or real recording is required.

| Case | Required result |
| --- | --- |
| Legacy guest, sign in A, logout, sign in B | Guest bytes preserved; no history/profile/key exposure and no automatic enqueue |
| A opt-in, record, logout while offline, B | A item remains A-owned; B default consent false; no delivery to B |
| Opt-in after old completed records | Old records remain local-only |
| Restart before send / after server acceptance with lost response | Durable same payload/key; same authorized receipt; no second history source |
| Logout during admitted transfer | Transfer cancelled and joined; late response cannot mutate B or retarget source |
| Missing/redaction/incomplete/unknown-completeness/oversize source | Visible stable withholding reason; no transport |
| Corrupt envelope, digest mismatch or foreign owner | Fail closed and preserve evidence; no transport |
| 401/403/409/422/429/5xx and network failure | Correct durable pause/failure/backoff; no unbounded validation retry |
| Needs participant / criteria | Acceptance visible separately; authorized resolution with no employee guess |
| Stale history/playback/summary/export/Local API await | Former-profile result cannot be presented after switch |

Baseline probe on the unchanged native revision: `bash Tests/run_meeting_session_store_checkpoint_tests.sh` passed 931 checks using the production persisted codecs, store, reading projection and protected exporter with synthetic data. It compiled with the existing Swift 5-mode `ExportedTranscript: Encodable` isolation warning at exporter line 1028. This is baseline evidence only; it does not validate account isolation, outbox transport, native targets or live server behavior.

The existing policy-only probe, `PICHI_PII_POLICY_ONLY=1 bash Tests/run_meeting_privacy_context_tests.sh`, also passed on the unchanged native sources. It uses actual segments/evidence and dictionary/redaction policy with synthetic inputs and deliberately does not fetch/build the native inference dependency or load a privacy model. These results do not establish model-based redaction accuracy.

Portable repository checks passed with `bash scripts/dev/check.sh`. Independent architecture/security review of inventory revision `1c299fb894c65e163adbe2d1915b169c56588518` confirmed the direct-store reference count and identified the standalone helper plus auxiliary dictionary state as missing. Both were added to this inventory. That review was static documentation/source analysis, not runtime verification of the proposed implementation.

Extend the existing `Tests/TranscriptSensitiveDictionaryTests.swift:70` isolated-defaults/admitted-redactor probe, `Tests/FluidDictationIntegrationTests/MeetingOwnerVoiceProfileTests.swift:127` temporary-store and stale-draft cases, `Tests/FluidDictationIntegrationTests/DictationE2ETests.swift:3559` injected pronunciation/learning fixture, and `Tests/FluidDictationIntegrationTests/SearchIndexTests.swift:409` isolated writer/defaults/index fixture. No generic test framework is needed.

N2 owns worktree `/Users/sabbah/.codex/worktrees/553d/pichi-voice`, branch `codex/pichi-sso-native-sync-20261022`. No app, UI, simulator, model, physical device, microphone or transport service has been started. The worktree remains active for the named dependency handoffs and implementation.
