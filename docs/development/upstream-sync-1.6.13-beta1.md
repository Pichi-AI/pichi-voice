# FluidVoice 1.6.13 beta 1 integration

## Pinned inputs and scope

| Input | Exact revision |
| --- | --- |
| Fetched downstream main | `59e5079066406ff2f2ecdec8c1c2395eaf69e052` |
| Published stable 1.6.12 | `8976f3aedc4f8fb3499a9a28c15fa29840f2b5f3` |
| Published 1.6.13-beta.1 | `800ff16c1d6a24c4bfaaa61d667e6320aa3b5124` |
| Fetched upstream/main during preparation | `0fccdeb014462e6f82889af38c7e9de92d87a130` |
| Reused reviewed PR 46/56 combined baseline | `6f60aabbe645c80da2347d5bf1d75fb30a9da6fe` |
| Additional original PR 47 mobile controls | `193921de51fe94a9f67a642f4d7541491e5105b9` |
| Task branch | `codex/upstream-sync-d15bd127be` |

The beta was published on October 25, 2026 at 09:45:47 UTC. The paginated releases endpoint returned 63 releases on one page. Stable 1.6.12 remains independently checked; the new beta contains it and the earlier beta.1 history. No existing open PR contains the new beta SHA. The new published tag adds 54 commits over stable 1.6.12. Unpublished upstream/main is not the update target.

This beta is published from a release branch outside upstream/main. The existing helper initially rejected that topology. Its bounded extension verifies an explicit canonical stable/beta application tag through the official GitHub host and repository, a nondraft publication with an uploaded macOS app image, and the exact recursively peeled tag SHA. Branches, missing releases, drafts, unrelated artifacts, identity mismatches and invalid tag chains remain rejected. The common-ancestry check is unchanged. Fourteen new synthetic cases and the existing helper suite passed; its independent review found no material findings.

The fixed helper was run with the explicit beta tag. An initial partial-clone blob fetch failed before writing a merge. Re-fetching the exact published tag without filtering hydrated the required Git objects. The direct main-to-beta rehearsal then exposed 49 conflict paths. Its conflict inventory was preserved and the clean rehearsal merge aborted. The task branch reused the already reviewed PR 46/56 baseline, integrated the three-path PR 47 control delta, and merged the exact beta SHA. This reduced the application merge to 17 conflicted paths without repeating the earlier stable resolutions. Existing PR 46/56 branches, main and frozen runtime were not changed. The new PR is stacked on PR 56.

## Conflict decisions

| Path | Resolution |
| --- | --- |
| `Info.plist` | Beta version with downstream build 35, above build 34. |
| `ContentView.swift` | Existing authoritative route, target/output cancellation and general AI prewarm remain; optional context is request-bound and capability-gated. |
| `Persistence/SettingsStore.swift` | New settings stay in the extracted key/model files; no duplicate enum or key declarations. Modifier-only cancel migration does not replace a valid C chord. |
| `Persistence/VoiceEngineLanguageCatalog.swift` | New model language metadata retains localized downstream language presentation. |
| `Services/DictionaryMatchPlayground.swift` | Preserve downstream lifecycle, localization and model contracts while adding hosted Pro metadata. |
| `Services/FluidAudioProvider.swift` | Preserve prepared model identity, vocabulary and joined retirement. Silent lead-in applies only to short ordinary dictation, never meeting/pronunciation alignment. |
| `Services/FluidServe/FluidServeMeetings.swift` | Keep bounded, identity-checked read-only access and canonical downstream summary input. |
| `Services/Meeting/MeetingSummaryController.swift` | Existing template summary cache gains a title-independent content hash; current prompt-version checks remain mandatory. |
| `Services/WhisperProvider.swift` | Qwen uses the existing native GGUF adapter and generic native run; Whisper retains its quality snapshot. Options follow the loaded model, not a mutable UI selection. |
| `Theme/Components/FluidVoiceBrandIcon.swift` | Retain the portable downstream artwork and appearance contract. |
| `UI/AISettings/FluidModelShowcaseCard.swift` | Keep selected-model indicators, typed presentation, shared typography, optional language and Russian accessibility copy; add preview badge and recommended memory. |
| `UI/AISettingsView+SpeechRecognition.swift` | Existing generic model operations and typed provider logos remain; no product-name substring dispatch. |
| `UI/MeetingSessionCanvases.swift` | Stable meeting identity preserves summary/view state on rename without removing correction/Undo behavior. |
| `UI/ReleaseHighlightsContent.swift` | Describe available public Pro/Qwen/caption changes. The absent proprietary Splash runtime is not advertised as supported. |
| `UI/SettingsSearch.swift` | Keep localized search and show context controls only when a registered model declares that capability. |
| `Views/BottomOverlayView.swift` | New bounded TextKit caption renderer retains portable typography, overlay ink, Reduce Motion, cancellation and hidden-work suppression. |
| `Tests/FluidDictationIntegrationTests/FluidServeTests.swift` | Preserve downstream API containment and canonical input/proof assertions while adding rename coverage. |

The automatically merged Xcode project repeated duplicate upstream app identity/version settings. Each macOS app configuration now has one downstream product/bundle identity and version 1.6.13-beta.1/build 35. Mobile identity/version are unchanged. The existing mobile generator restores unique explicit memberships. The upstream FluidAudio revision is pinned consistently across package manifests and Xcode to `386f7195670b77f2954c7ee143ec63fcb50b6c3b`.

The latest PR 47 delta adds full-row hit areas and native settings/participant rows. The tested `activeSpeakers` correction is retained. These changed mobile controls need new focused combined-candidate verification; older simulator/device results keep their original source provenance.

## Architecture and semantic review

Pro extends the existing Parakeet descriptor/catalog, verified archive installation and pronunciation identity. Qwen 1.7B uses the existing transcription provider and native GGUF transport with Apple Silicon admission, its own language options and the typed Qwen logo. Legacy Qwen preview remains disabled. GigaAM's Russian default, download/import contracts, dictionaries and settings migrations remain unchanged. No per-model constructor was added to a common meeting coordinator.

Context remains off by default and only runs for a registered, capable local cleanup model. S1-mini retains the default false capability. Settings/search use the same capability query and localized resources. The feature switch does not request an OS permission. Source review found and repaired two material upstream issues: canceled readers could overlap subsequent reads, and whole-window OCR could reintroduce a secure descendant omitted from Accessibility text. One reader owns admission until completion; late canceled output is suppressed. Secure, incomplete or unknown bounded Accessibility traversal denies OCR. Synthetic tests cover suspended cleanup, no queued replacements, late output, secure siblings and incomplete traversal. No actual screen read or permission change was used for these tests.

Template `manual-summary-*` files gain content hash version 2 so a title-only rename preserves their text. Missing, stale and future prompt versions are not promoted during migration. The separate grounded artifact v6 proof/schema is unchanged; a rename still invalidates that artifact under its existing contract. This change does not fix the previously accepted summary semantic-quality limitations.

The first combined native build compiled the app but stopped on a renamed availability argument in a test fixture. The first mobile build exposed a shared coordinator referring to the macOS summary controller. The persisted summary data and its existing migration operation now live in a shared Foundation file, with the macOS controller retaining a source-compatible alias. The shared coordinator consumes that data operation; iOS does not import the macOS model/UI stack. Both failed build attempts are retained. The follow-up uses actual per-attribute Accessibility error decoding: an overall successful batch cannot turn an unreadable container into a known leaf. Unknown protected metadata denies OCR, with decoder-level synthetic regressions. Optional non-safety attributes remain optional; unsupported terminal children are conservatively limited to known safe Accessibility text.

## Verification and remaining gates

At this report's initial candidate, combined native builds/tests and independent integrated review are pending. Dependency resolution passed in an owned worktree. Scope probes passed for helper verification, actual catalog/model metadata, canonical meeting/API inputs and caption layout with direct Cyrillic glyph coverage. These projections and syntax checks do not establish a compiled or functioning combined application.

The 221 hotkey/paste tests and previous mobile/device results belong to earlier candidates and are not fresh beta acceptance. The existing physical C cancellation failure, active-caption movement and all-system continuity limitations remain unresolved. The frozen Debug app and editor awaiting the human D/C trial are preserved. New native tests must use a separate bundle/data namespace and owned build/package directories. New mobile controls require both simulator form factors and native visual review before any later physical delivery. No automatic merge, production app replacement, model installation or new OS grant is part of this preparation.

Private recordings, dictionaries, profiles, models, credentials, signing material and local paths remain outside Git. Failed attempts, exact commands, source/file hashes, timings and cleanup receipts are retained in ignored local evidence. This report must be updated with actual combined checks and reviewed revision before the draft is considered ready.
