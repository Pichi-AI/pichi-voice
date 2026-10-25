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

The beta was published on October 25, 2026 at 09:45:47 UTC. The paginated releases endpoint returned 63 releases on one page. Stable 1.6.12 remains independently checked; the new beta contains it and the earlier v1.6.12-beta.1 history. No existing open PR contains the new beta SHA. The new published tag adds 54 commits over stable 1.6.12. Unpublished upstream/main is not the update target.

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

Context remains off by default and only runs for a registered, capable local cleanup model. S1-mini retains the default false capability. Settings/search use the same capability query and localized resources. The feature switch does not request an OS permission. Source review found and repaired material upstream issues: canceled readers could overlap subsequent reads, and whole-window OCR could reintroduce a secure descendant omitted from Accessibility text. One reader owns admission until completion; late canceled output is suppressed. Secure, incomplete or unknown bounded Accessibility traversal denies OCR. Synthetic tests cover suspended cleanup, no queued replacements, late output, secure siblings and incomplete traversal. No actual screen read or permission change was used for these tests.

Template `manual-summary-*` files gain content hash version 2 so a title-only rename preserves their text. Missing, stale and future prompt versions are not promoted during migration. The separate grounded artifact v6 proof/schema is unchanged; a rename still invalidates that artifact under its existing contract. This change does not fix the previously accepted summary semantic-quality limitations.

The first combined native build compiled the app but stopped on a renamed availability argument in a test fixture. The first mobile build exposed a shared coordinator referring to the macOS summary controller. The persisted summary data and its existing migration operation now live in a shared Foundation file, with the macOS controller retaining a source-compatible alias. The shared coordinator consumes that data operation; iOS does not import the macOS model/UI stack. Both failed build attempts are retained. The follow-up uses actual per-attribute Accessibility error decoding: an overall successful batch cannot turn an unreadable container into a known leaf. Unknown protected metadata denies OCR, with decoder-level synthetic regressions. The final focused-field gate also requires known-public role/subrole evidence before accepting either supplied cursor text or a fresh cursor read; nil focused targets discard unattributable cursor text. Reader-level tests cover unknown, secure and public fields, cancellation and captured-window-only behavior. Optional non-safety attributes remain optional; unsupported terminal children are conservatively limited to known safe Accessibility text.

## Verification and remaining gates

The integrated source candidate is `89dfafb827dad41f090a46262313d92cf384c8ec`. Native tests use an independently frozen, strictly signed copy with a separate test bundle/data namespace. The copy preserves all 19 effective Xcode entitlement keys, 124 file hashes and 18 symlinks. Only the existing CTranscribe versioned framework layout needed normalization before local signing; the layout normalization preserved its executable before normal local signing. No system permission database was modified.

| Check | Actual result |
| --- | --- |
| Portable repository checks | Final PASS at `89dfafb8`, 43.164s. Earlier `9caa1d39` passed in 53.005s; first merged candidate passed in 48.788s. |
| macOS signed Debug build-for-testing | PASS at final source `89dfafb8`, 29.274s; all native test sources compile. |
| iOS Simulator Debug build-for-testing | PASS at `9caa1d39`, 93.572s. Final mobile inputs differ only by an EOF blank-line removal; focused-context code/tests are macOS-only. |
| First affected headless native batch | 600 total, 581 passed, 0 failed, 19 explicitly skipped, 73.392s at final source. The isolated host uses private named/fake pasteboards and injected services. |
| Actual public model runtime batch | 3/3 passed, 0 skipped, 126.562s at final source. Fresh staged Mini/Pico/Pro installation, shipped verification sentence, transcription and pronunciation frames; native Qwen fixture/cache preservation; synthetic Russian GigaAM plus S1-mini pipeline. |
| Additional affected headless native batch | 343/343 passed, 0 skipped, 20.105s at final source. Provider ownership, cancellation, capture recovery, API lifetime, settings and private pasteboard contracts use injected transports/engines. |
| Actual S1-mini semantic fixture | 1/1 passed, 0 skipped, 3.074s; four English/Russian inputs preserve negation, literal invoice/amount values and corrected dates. |
| macOS Release arm64 | PASS at final source, 343.489s; actual arm64 binary, downstream identity and version/build verified. |
| macOS Release x86_64 | PASS at final source, 307.662s; actual x86_64 binary and downstream identity/version verified. Cross-compiled; physical Intel runtime is unverified. |
| Independent combined source/architecture review | Final GO at `89dfafb8`, no remaining P1/P2 findings in reviewed code. Original OCR and focused-cursor privacy findings were repaired and reviewed again. |

Qwen's public artifact was resolved to its publisher revision and checked against the publisher's LFS SHA-256 and exact 2,185,030,624-byte size before inference. Existing approved public GigaAM/S1-mini inputs were cloned into task-owned storage and rechecked by hash. No microphone or private recording was used for these model checks. Timings were measured under concurrent verification load and are not performance benchmarks.

Both mobile selectors completed on both owned iOS 27.0 simulators at `9caa1d39`: 4 test cases passed, 0 failed or skipped. Each correction case covers EN/light and RU/dark, full-fragment and single-word reassignment, both Undo paths, correction to the owner, termination/reopen persistence and normal reassignment back to the fixture. There were 56 reviewed iPhone gates and 54 iPad gates. Four native editor frames were also reviewed by the parent and displayed to the user; human acceptance has not been recorded. The selector shows the inline Save/Cancel/This is me controls but does not separately press Save rename or the This is me owner-transfer action.

| Successful simulator run | Launcher wall time | Captured frames | Missed slots | Capture errors |
| --- | --- | --- | --- | --- |
| iPhone replay onboarding | 91.154s | 91 | 0 | 0 |
| iPad replay onboarding | 100.802s | 85 | 15 | 0 |
| iPhone correction matrix | 1418.670s | 1395 | 22 | 2 |
| iPad correction matrix | 1279.269s | 953 | 325 | 1 |

The long correction wall times include exact native-frame review/acknowledgement. Functional assertions passed without source or assertion changes. Continuous capture has incomplete one-second coverage; every retained frame/error and missed slot stays in private evidence. The continuous review covered 167 unique iPhone correction frames, 84 replay frames and retained prelaunch frames, plus 164 unique iPad frames. Two stale-container preflight attempts and a first-valid-frame preflight failure stopped before test execution; their logs/captures are retained. Readiness staging was corrected only in ignored orchestration scripts.

The fixture restoration is normal reassignment, not Undo or raw byte restoration. All three speaker objects and all five segment contents, IDs, times and final assignments match the fixture. One corrected segment intentionally retains `isUserSpeakerAssigned=true` and assignment revision 4 after the two language passes, consistent with the existing model contract. The initial overstrict raw-equality audit is retained; no data was rewritten to conceal the provenance difference.

The 221 older hotkey/paste tests and earlier mobile/device results retain their original source provenance. They are not fresh beta acceptance. During the pending human D/C trial, tests that show windows, install a real global event tap, capture microphone/system audio or use physical devices are deferred. The source audit found actual delayed tap installation in several otherwise synthetic hotkey fixtures, so these are excluded rather than allowed to interfere with the operator. An opt-in AEC probe with a possible private `/tmp` request fallback is also excluded. The intentionally flaky upstream Whisper tiny fixture remains outside the available scope.

The physical Ctrl+Option+Shift+C cancellation failure, active-caption movement and all-system continuity limitations remain unresolved. The older frozen Debug app and editor awaiting the human D/C trial are preserved. Mobile simulator tests do not establish physical-device recording or final merged-main delivery. Proprietary Splash runtime, external cloud calls and physical Intel runtime remain unverified. No automatic merge, working-app replacement or new OS grant was performed. Model installations belonged to task-owned verification caches.

Private recordings, dictionaries, profiles, models, credentials, signing material and local paths remain outside Git. Exact commands, immutable source and artifact hashes, xcresults, native frames, retained failures and cleanup receipts stay in ignored local evidence. The new PR remains draft until its remaining acceptance gates pass.

## Resource handoff

All native build/test jobs joined and task-owned inference runtimes exited. The Mac/mobile build directories, package checkouts, transient model copies and isolated native test preferences/caches were removed after verification and needed independent preservation. Release architecture/identity/hash manifests remain; unneeded unsigned Release app copies were removed. The exact signed Debug candidate, test results, native frames and a verified public Qwen input remain in private artifact storage for pending acceptance and future release regression. No shared model cache was purged.

Simulator/container and worktree lifecycle receipts belong to the private final handoff. Recoverable source branches and verification evidence are preserved before removing owned worktrees. The earlier PR 46/56 runtime, editor and source worktrees remain explicitly reserved for the unresolved physical D/C trial. The working application and other sessions' resources are preserved.
